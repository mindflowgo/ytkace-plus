#import <CommonCrypto/CommonDigest.h>
#import <objc/message.h>
#import "RecommendationCodec.h"

NSString *YTRCMarkerText(void) { return @"RECSRV"; }

NSString *YTRCDomain(void) { return @"YTKACERecommendations"; }

NSString *YTRCErrorString(NSError *error) {
    if (error == nil) return nil;
    NSString *message = error.localizedDescription;
    return message.length != 0 ? message : [NSString stringWithFormat:@"error %ld", (long)error.code];
}

// Writes the varint encoding of value into out, returns the byte count.
static NSUInteger YTRCWriteVarint(NSUInteger value, uint8_t *out) {
    NSUInteger index = 0;
    while (value >= 0x80) {
        out[index++] = (uint8_t)(value | 0x80);
        value >>= 7;
    }
    out[index++] = (uint8_t)value;
    return index;
}

NSData *YTRCMarkerFieldBytes(NSUInteger fieldNumber) {
    uint8_t tag[10];
    NSUInteger tagLength = YTRCWriteVarint((fieldNumber << 3) | 2, tag);
    NSData *text = [YTRCMarkerText() dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t length = (uint8_t)text.length; // Marker text is short by contract.
    NSMutableData *bytes = [NSMutableData dataWithCapacity:tagLength + 1 + text.length];
    [bytes appendBytes:tag length:tagLength];
    [bytes appendBytes:&length length:1];
    [bytes appendData:text];
    return bytes;
}

BOOL YTRCPayloadHasMarker(NSData *data, NSUInteger fieldNumber) {
    if (data.length == 0 || fieldNumber == 0) return NO;
    NSData *marker = YTRCMarkerFieldBytes(fieldNumber);
    if (marker.length > data.length) return NO;
    const uint8_t *needle = (const uint8_t *)marker.bytes;
    const uint8_t *haystack = (const uint8_t *)data.bytes;
    NSUInteger needleLength = marker.length, haystackLength = data.length;
    if (needleLength > haystackLength) return NO;
    for (NSUInteger offset = 0; offset + needleLength <= haystackLength; offset++) {
        if (haystack[offset] != needle[0]) continue;
        if (memcmp(haystack + offset, needle, needleLength) == 0) return YES;
    }
    return NO;
}

NSString *YTRCSha256Prefix(NSData *data) {
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    char hex[17];
    for (int index = 0; index < 8; index++) snprintf(hex + index * 2, 3, "%02x", digest[index]);
    return [NSString stringWithUTF8String:hex];
}

NSData *YTRCSerializeMessage(id message, NSUInteger maxBytes, NSError **error) {
    if (message == nil) {
        if (error != nullptr)
            *error = [NSError errorWithDomain:YTRCDomain() code:5
                userInfo:@{NSLocalizedDescriptionKey: @"response object is nil"}];
        return nil;
    }
    SEL sizeSelector = NSSelectorFromString(@"serializedSize");
    Method sizeMethod = class_getInstanceMethod([message class], sizeSelector);
    if (sizeMethod == nullptr || !YTRCMethodMatches(sizeMethod, "Q@:")) {
        if (error != nullptr)
            *error = [NSError errorWithDomain:YTRCDomain() code:1
                userInfo:@{NSLocalizedDescriptionKey: @"response does not implement serializedSize"}];
        return nil;
    }
    NSUInteger declared = ((NSUInteger (*)(id, SEL))objc_msgSend)(message, sizeSelector);
    if (declared == NSUIntegerMax || declared > maxBytes) {
        if (error != nullptr)
            *error = [NSError errorWithDomain:YTRCDomain() code:2
                userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:
                    @"serialized size %lu exceeds the %lu byte cap", (unsigned long)declared, (unsigned long)maxBytes]}];
        return nil;
    }
    id encoded = YTRCObject(message, @"data");
    if (![encoded isKindOfClass:NSData.class]) {
        if (error != nullptr)
            *error = [NSError errorWithDomain:YTRCDomain() code:3
                userInfo:@{NSLocalizedDescriptionKey: @"response does not serialize through data"}];
        return nil;
    }
    NSData *data = encoded;
    if (data.length > maxBytes) {
        if (error != nullptr)
            *error = [NSError errorWithDomain:YTRCDomain() code:4
                userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:
                    @"serialized %lu bytes exceeds the %lu byte cap", (unsigned long)data.length, (unsigned long)maxBytes]}];
        return nil;
    }
    return data;
}

id YTRCParseMessage(NSData *data, Class expectedClass, NSError **error) {
    if (data == nil || expectedClass == Nil) {
        if (error != nullptr)
            *error = [NSError errorWithDomain:YTRCDomain() code:10
                userInfo:@{NSLocalizedDescriptionKey: @"payload or expected class missing"}];
        return nil;
    }
    SEL withRegistry = NSSelectorFromString(@"parseFromData:extensionRegistry:error:");
    SEL plain = NSSelectorFromString(@"parseFromData:error:");
    id registry = YTRCObject(NSClassFromString(@"GoogleGlobalExtensionRegistry"), @"extensionRegistry");
    id parsed = nil;
    NSError *parseError = nil;
    @try {
        if (registry != nil && YTRCMethodMatches(class_getClassMethod(expectedClass, withRegistry), "@@:@@^@")) {
            parsed = ((id (*)(id, SEL, id, id, NSError **))objc_msgSend)(expectedClass, withRegistry, data, registry, &parseError);
        } else if (YTRCMethodMatches(class_getClassMethod(expectedClass, plain), "@@:@^@")) {
            parsed = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(expectedClass, plain, data, &parseError);
        }
    } @catch (NSException *exception) {
        parseError = [NSError errorWithDomain:YTRCDomain() code:11
            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"parse threw %@", exception.name]}];
        parsed = nil;
    }
    if (parsed == nil || [parsed class] != expectedClass) {
        if (error != nullptr) {
            NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithObject:
                (parsed != nil ? [NSString stringWithFormat:@"parsed class %@ does not match the expected %@",
                    NSStringFromClass([parsed class]), NSStringFromClass(expectedClass)]
                    : @"parser missing or parse failed") forKey:NSLocalizedDescriptionKey];
            if (parseError != nil && parseError.localizedDescription.length != 0)
                userInfo[NSLocalizedFailureReasonErrorKey] = parseError.localizedDescription;
            *error = [NSError errorWithDomain:YTRCDomain() code:12 userInfo:userInfo];
        }
        return nil;
    }
    return parsed;
}
