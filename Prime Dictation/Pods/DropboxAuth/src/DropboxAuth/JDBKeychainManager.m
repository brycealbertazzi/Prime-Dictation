//
// Copyright © 2016 Daniel Farrelly
//
// Redistribution and use in source and binary forms, with or without modification,
// are permitted provided that the following conditions are met:
//
// *	Redistributions of source code must retain the above copyright notice, this list
//		of conditions and the following disclaimer.
// *	Redistributions in binary form must reproduce the above copyright notice, this
//		list of conditions and the following disclaimer in the documentation and/or
//		other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
// ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
// IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
// INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
// BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
// LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
// OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
// ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

@import Security;
#import <DropboxAuth/JDBKeychainManager.h>

@implementation JDBKeychainManager

+ (BOOL)setValue:(NSString *)value forKey:(NSString *)key {
	if( key == nil || value == nil ) return NO;

	NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];

	if( data == nil ) { return NO; }

	NSDictionary *query = [self jsm_queryWithDict:@{ (__bridge id)kSecAttrAccount: key, (__bridge id)kSecValueData: data }];

	SecItemDelete((__bridge CFDictionaryRef)query);

	return SecItemAdd((__bridge CFDictionaryRef)query, nil) == noErr;
}

+ (NSData *)getAsData:(NSString *)key {
	if( key == nil ) return nil;

	NSDictionary *query = [self jsm_queryWithDict:@{ (__bridge id)kSecAttrAccount: key,
												   (__bridge id)kSecReturnData: (__bridge id)kCFBooleanTrue,
												   (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne }];

	CFDataRef dataResult = NULL;
	OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&dataResult);

	if( status != noErr ) { return nil; }

	return (__bridge NSData *)dataResult;
}

+ (NSString *)valueForKey:(NSString *)key {
	if( key == nil ) return nil;

	NSData *data = [self getAsData:key];

	if( data == nil ) { return nil; }

	return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

+ (BOOL)removeValueForKey:(NSString *)key {
	if( key == nil ) return NO;

	NSDictionary *query = [self jsm_queryWithDict:@{ (__bridge id)kSecAttrAccount: key }];
	return SecItemDelete((__bridge CFDictionaryRef)query) == noErr;
}

+ (NSArray<NSString *> *)getAll {
	NSDictionary *query = [self jsm_queryWithDict:@{ (__bridge id)kSecReturnAttributes: (__bridge id)kCFBooleanTrue,
												 (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll }];

	CFArrayRef dataResult = NULL;
	OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&dataResult);

	if( status != noErr ) { return @[]; }

	NSArray *results = (__bridge NSArray *)dataResult;
	if( ! [results isKindOfClass:[NSArray class]] ) {
		results = @[];
	}

	NSMutableArray *mappedResults = [NSMutableArray array];
	[results enumerateObjectsUsingBlock:^(NSDictionary * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
		mappedResults[idx] = obj[@"acct"];
	}];
	return [mappedResults copy];
}

+ (BOOL)clearAll {
	NSDictionary *query = [self jsm_queryWithDict:@{}];
	return SecItemDelete((__bridge CFDictionaryRef)query) == noErr;
}

#pragma mark - Utilities

+ (NSDictionary *)jsm_queryWithDict:(NSDictionary<NSString *, id> *)query {
	NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
	NSMutableDictionary *queryDict = [query mutableCopy];

	queryDict[(__bridge id)kSecClass] = (__bridge id)kSecClassGenericPassword;
	queryDict[(__bridge id)kSecAttrService] = [NSString stringWithFormat:@"%@.dropbox.authv2",bundleId];

	return queryDict;
}

+ (void)jsm_listAllItems {
	NSDictionary *query = [self jsm_queryWithDict:@{ (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
												 (__bridge id)kSecReturnAttributes: (__bridge id)kCFBooleanTrue,
												 (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll }];

	CFArrayRef dataResult = NULL;
	OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&dataResult);

	if( status != noErr ) { return; }
	
	NSArray *results = (__bridge NSArray *)dataResult;
	if( ! [results isKindOfClass:[NSArray class]] ) {
		results = @[];
	}
	NSMutableArray *mappedResults = [NSMutableArray array];
	[results enumerateObjectsUsingBlock:^(NSDictionary * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
		mappedResults[idx] = @[obj[@"svce"],obj[@"acct"]];
	}];
	NSLog(@"dbgListAllItems: %@",mappedResults);
}

@end
