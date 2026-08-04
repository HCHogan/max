#import <Foundation/Foundation.h>
#include <stdlib.h>
#include <string.h>

char *max_decode_imessage_mentions(const unsigned char *bytes, size_t length) {
  @autoreleasepool {
    @try {
      NSData *data = [NSData dataWithBytes:bytes length:length];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
      id decoded = [NSUnarchiver unarchiveObjectWithData:data];
#pragma clang diagnostic pop
      if (![decoded isKindOfClass:[NSAttributedString class]]) {
        return NULL;
      }

      NSAttributedString *text = (NSAttributedString *)decoded;
      NSMutableArray *mentions = [NSMutableArray array];
      NSUInteger index = 0;
      while (index < text.length) {
        NSRange range;
        id value = [text attribute:@"__kIMMentionConfirmedMention"
                           atIndex:index
                    effectiveRange:&range];
        if (![value isKindOfClass:[NSString class]] || range.length == 0) {
          index = NSMaxRange(range);
          continue;
        }
        NSString *display = [[text string] substringWithRange:range];
        [mentions addObject:@{
          @"handle": value,
          @"display": display,
          @"utf16_location": @(range.location),
          @"utf16_length": @(range.length)
        }];
        index = NSMaxRange(range);
      }

      NSData *json = [NSJSONSerialization dataWithJSONObject:mentions options:0 error:nil];
      if (json == nil) {
        return NULL;
      }
      char *result = malloc(json.length + 1);
      if (result == NULL) {
        return NULL;
      }
      memcpy(result, json.bytes, json.length);
      result[json.length] = '\0';
      return result;
    } @catch (NSException *exception) {
      (void)exception;
      return NULL;
    }
  }
}
