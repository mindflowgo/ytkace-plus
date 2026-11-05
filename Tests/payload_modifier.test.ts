// Unit tests for the payload modifier (bun test Tests/payload_modifier.test.ts).
// Builds fixtures with the same wire shapes verified against the real payload.

import { describe, expect, test } from "bun:test";
import {
  findShelves,
  removeShelves,
  removeShelfCard,
  replaceShelfCard,
  insertShelfCard,
  setShelfCards,
  cloneCardAs,
  replaceShelfCardWithClone,
} from "../server/payload-modifier.ts";
import { encodeWireMessage, parseWireMessage, recodePayload, type WireField } from "../server/wire.ts";

const encoder = new TextEncoder();

function bytesField(field: number, bytes: Uint8Array): WireField {
  return { field, wire: 2, bytes };
}
function textField(field: number, text: string): WireField {
  return { field, wire: 2, bytes: encoder.encode(text) };
}
function msgField(field: number, fields: WireField[]): WireField {
  return { field, wire: 2, bytes: encodeWireMessage(fields) };
}

function lockupCard(videoId: string, title: string, byline: string): Uint8Array {
  return encodeWireMessage([
    msgField(1, [msgField(2, [textField(1, "23:04")])]),          // media (f2 = duration)
    msgField(2, [textField(1, title), textField(3, "tracking")]), // metadata (f1 = title)
    textField(6, `//www.youtube.com/watch?v=${videoId}`),
    textField(7, videoId),
    textField(18, videoId),
    textField(2, byline),                                         // a11y row
    msgField(14, [msgField(169495254, [msgField(98150882, [textField(1, "Send feedback")])])]),
    msgField(6, [msgField(169495254, [msgField(462702848, [msgField(48687757, [
      textField(1, videoId), textField(36, title), textField(37, byline.split(" ")[0]),
    ])])])]),
  ]);
}

function shelf(heading: string, cards: Uint8Array[]): Uint8Array {
  const entry: WireField[] = [
    msgField(1, [msgField(19, [textField(2, "Action menu")]), textField(20, heading), textField(26, heading)]),
    msgField(5, [textField(1, "shelf-params")]),
    ...cards.map((card) => bytesField(9, card)),
  ];
  return encodeWireMessage([msgField(312131490, [msgField(20, entry)])]);
}

function payloadWith(shelves: Uint8Array[]): Uint8Array {
  return encodeWireMessage([
    textField(1, "response-context"),
    ...shelves.map((bytes) => bytesField(9, bytes)),
    msgField(777, [textField(1, "framework")]),
  ]);
}

function containsText(payload: Uint8Array, text: string): boolean {
  const needle = encoder.encode(text);
  outer: for (let i = 0; i + needle.length <= payload.length; i++) {
    for (let j = 0; j < needle.length; j++) {
      if (payload[i + j] !== needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

const shelfA = () => shelf("Breaking news", [
  lockupCard("CMH1vWoqK_0", "What Democratic control of Congress means", "CTV News 3.9K 48 min ago"),
  lockupCard("K0ywyEB_OHc", "Voters hand Democrats Senate control", "The Canadian Press 4.5K 1h ago"),
]);
const shelfB = () => shelf("Recommended", [
  lockupCard("AAAAAAAAAAA", "A regular video title", "Some Channel 1K 1h ago"),
]);

describe("wire codec", () => {
  test("recode is byte-identical for the fixture", () => {
    const payload = payloadWith([shelfA(), shelfB()]);
    const recoded = recodePayload(payload);
    expect(recoded).not.toBeNull();
    expect(recoded!.identical).toBe(true);
  });
});

describe("findShelves", () => {
  test("lists modern shelves with headings and cards", () => {
    const shelves = findShelves(payloadWith([shelfA(), shelfB()]));
    expect(shelves.map((s) => s.heading)).toEqual(["Breaking news", "Recommended"]);
    expect(shelves[0].kind).toBe("modern");
    expect(shelves[0].cardCount).toBe(2);
    expect(shelves[1].cardCount).toBe(1);
  });
});

describe("removeShelves", () => {
  test("drops only the matching shelf and preserves the rest", () => {
    const original = payloadWith([shelfA(), shelfB()]);
    const result = removeShelves(original, ["Breaking news"]);
    expect(result.removed).toEqual(["Breaking news"]);
    expect(containsText(result.bytes, "Breaking news")).toBe(false);
    expect(containsText(result.bytes, "CMH1vWoqK_0")).toBe(false);
    expect(containsText(result.bytes, "Recommended")).toBe(true);
    expect(containsText(result.bytes, "AAAAAAAAAAA")).toBe(true);
    expect(containsText(result.bytes, "framework")).toBe(true);
    const shelves = findShelves(result.bytes);
    expect(shelves.map((s) => s.heading)).toEqual(["Recommended"]);
  });

  test("no-op when the heading matches nothing", () => {
    const original = payloadWith([shelfB()]);
    const result = removeShelves(original, ["Nope"]);
    expect(result.removed).toEqual([]);
    expect(result.bytes).toEqual(original);
  });
});

describe("card operations", () => {
  test("removeShelfCard removes the indexed card only", () => {
    const original = payloadWith([shelfA()]);
    const result = removeShelfCard(original, "Breaking news", 0);
    expect(result.changed).toBe(true);
    expect(containsText(result.bytes, "CMH1vWoqK_0")).toBe(false);
    expect(containsText(result.bytes, "K0ywyEB_OHc")).toBe(true);
    expect(findShelves(result.bytes)[0].cardCount).toBe(1);
  });

  test("replaceShelfCard swaps in a cloned card", () => {
    const original = payloadWith([shelfA()]);
    const template = findShelves(original)[0].cards[0];
    const clone = cloneCardAs(template, {
      newId: "ZZZZZZZZZZZ",
      newTitle: "A brand new inserted title",
    });
    const result = replaceShelfCard(original, "Breaking news", 1, clone);
    expect(result.changed).toBe(true);
    expect(containsText(result.bytes, "K0ywyEB_OHc")).toBe(false);
    expect(containsText(result.bytes, "ZZZZZZZZZZZ")).toBe(true);
    expect(containsText(result.bytes, "A brand new inserted title")).toBe(true);
    expect(findShelves(result.bytes)[0].cardCount).toBe(2);
  });

  test("insertShelfCard adds a card at the given index", () => {
    const original = payloadWith([shelfA()]);
    const template = findShelves(original)[0].cards[0];
    const clone = cloneCardAs(template, { newId: "YYYYYYYYYYY", newTitle: "Inserted title" });
    const result = insertShelfCard(original, "Breaking news", 1, clone);
    expect(result.changed).toBe(true);
    expect(findShelves(result.bytes)[0].cardCount).toBe(3);
  });

  test("setShelfCards replaces the whole list", () => {
    const original = payloadWith([shelfA()]);
    const template = findShelves(original)[0].cards[0];
    const only = cloneCardAs(template, { newId: "XXXXXXXXXXX", newTitle: "Only card" });
    const result = setShelfCards(original, "Breaking news", [only]);
    expect(findShelves(result.bytes)[0].cardCount).toBe(1);
    expect(containsText(result.bytes, "CMH1vWoqK_0")).toBe(false);
    expect(containsText(result.bytes, "XXXXXXXXXXX")).toBe(true);
  });

  test("replaceShelfCardWithClone combines clone + replace", () => {
    const original = payloadWith([shelfB()]);
    const template = findShelves(original)[0].cards[0];
    const result = replaceShelfCardWithClone(original, "Recommended", 0, template, {
      newId: "WWWWWWWWWWW",
      newTitle: "Cloned replacement",
    });
    expect(result.changed).toBe(true);
    expect(containsText(result.bytes, "AAAAAAAAAAA")).toBe(false);
    expect(containsText(result.bytes, "WWWWWWWWWWW")).toBe(true);
  });
});

describe("cloneCardAs", () => {
  test("rewrites id, every id occurrence, metadata and nav titles", () => {
    const template = lockupCard("CMH1vWoqK_0", "Old card title", "CTV News 3.9K 48 min ago");
    const clone = cloneCardAs(template, { newId: "NEWVIDEO123", newTitle: "New card title" });
    expect(containsText(clone, "CMH1vWoqK_0")).toBe(false);
    expect(containsText(clone, "NEWVIDEO123")).toBe(true);
    expect(containsText(clone, "Old card title")).toBe(false);
    expect(containsText(clone, "New card title")).toBe(true);
    // Both the metadata title and the navData title were rewritten.
    let occurrences = 0;
    const needle = encoder.encode("New card title");
    outer: for (let i = 0; i + needle.length <= clone.length; i++) {
      for (let j = 0; j < needle.length; j++) if (clone[i + j] !== needle[j]) continue outer;
      occurrences++;
      i += needle.length - 1;
    }
    expect(occurrences).toBe(2);
  });

  test("rejects templates without a videoId", () => {
    expect(() => cloneCardAs(encodeWireMessage([textField(1, "no id here")]), { newId: "AAAAAAAAAAA" }))
      .toThrow();
  });
});
