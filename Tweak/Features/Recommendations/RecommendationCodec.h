#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "RecommendationRuntime.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * _Nonnull YTRCMarkerText(void); // "RECSRV"
FOUNDATION_EXPORT NSString * _Nonnull YTRCDomain(void); // NSError domain for this module.

// Serializes a native protobuf message through its data/serializedSize selectors.
// Errors: missing selector, declared or actual size above maxBytes.
FOUNDATION_EXPORT NSData * _Nullable YTRCSerializeMessage(id _Nullable message, NSUInteger maxBytes,
                                                         NSError * _Nullable * _Nullable error);
// Parses replacement bytes into exactly expectedClass using the global extension
// registry. Any parse failure or class mismatch returns nil.
FOUNDATION_EXPORT id _Nullable YTRCParseMessage(NSData *data, Class expectedClass, NSError * _Nullable * _Nullable error);
// Scans raw payload bytes for the mock server's length-delimited marker field
// (varint tag (fieldNumber << 3 | 2) followed by the literal marker text).
FOUNDATION_EXPORT BOOL YTRCPayloadHasMarker(NSData *data, NSUInteger fieldNumber);
FOUNDATION_EXPORT NSData * _Nonnull YTRCMarkerFieldBytes(NSUInteger fieldNumber);
FOUNDATION_EXPORT NSString * _Nonnull YTRCSha256Prefix(NSData *data); // 16 hex chars; never the payload.
FOUNDATION_EXPORT NSString *YTRCErrorString(NSError * _Nullable error);

NS_ASSUME_NONNULL_END
