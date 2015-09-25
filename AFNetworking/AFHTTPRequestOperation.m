// AFHTTPRequestOperation.m
// Copyright (c) 2011–2015 Alamofire Software Foundation (http://alamofire.org/)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "AFHTTPRequestOperation.h"

// 创建GCD并发队列
// 单例
static dispatch_queue_t http_request_operation_processing_queue() {
    static dispatch_queue_t af_http_request_operation_processing_queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        af_http_request_operation_processing_queue = dispatch_queue_create("com.alamofire.networking.http-request.processing", DISPATCH_QUEUE_CONCURRENT);
    });

    return af_http_request_operation_processing_queue;
}

// 创建GCD组
// 单例
static dispatch_group_t http_request_operation_completion_group() {
    static dispatch_group_t af_http_request_operation_completion_group;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        af_http_request_operation_completion_group = dispatch_group_create();
    });

    return af_http_request_operation_completion_group;
}

#pragma mark -

@interface AFURLConnectionOperation ()
@property (readwrite, nonatomic, strong) NSURLRequest *request;
// NSURLResponse
@property (readwrite, nonatomic, strong) NSURLResponse *response;
@end

@interface AFHTTPRequestOperation ()
// NSHTTPURLResponse 继承自 NSURLResponse
@property (readwrite, nonatomic, strong) NSHTTPURLResponse *response;
// responseObject
@property (readwrite, nonatomic, strong) id responseObject;
// responseSerializationError
@property (readwrite, nonatomic, strong) NSError *responseSerializationError;
@property (readwrite, nonatomic, strong) NSRecursiveLock *lock;
@end

@implementation AFHTTPRequestOperation
@dynamic response;
@dynamic lock;

// 初始化方法
- (instancetype)initWithRequest:(NSURLRequest *)urlRequest {
    self = [super initWithRequest:urlRequest];
    if (!self) {
        return nil;
    }
    // 初始化AFHTTPResponseSerializer，返回值解析，并不是单例！!
    self.responseSerializer = [AFHTTPResponseSerializer serializer];

    return self;
}

// 设置AFHTTPResponseSerializer
- (void)setResponseSerializer:(AFHTTPResponseSerializer <AFURLResponseSerialization> *)responseSerializer {
    NSParameterAssert(responseSerializer);
    // lock
    [self.lock lock];
    // Setting a response serializer will clear out any cached value
    _responseSerializer = responseSerializer;
    // 初始化置为nil
    self.responseObject = nil;
    self.responseSerializationError = nil;
    [self.lock unlock];
}

// 生成返回对象
- (id)responseObject {
    [self.lock lock];
    if (!_responseObject && [self isFinished] && !self.error) {
        NSError *error = nil;
        // 由AFHTTPResponseSerializer生成responseObject
        // NSURLResponse
        self.responseObject = [self.responseSerializer responseObjectForResponse:self.response data:self.responseData error:&error];
        if (error) {
            // 赋值给responseSerializationError
            self.responseSerializationError = error;
        }
    }
    [self.lock unlock];

    return _responseObject;
}

- (NSError *)error {
    if (_responseSerializationError) {
        return _responseSerializationError;
    } else {
        return [super error];
    }
}

#pragma mark - AFHTTPRequestOperation

- (void)setCompletionBlockWithSuccess:(void (^)(AFHTTPRequestOperation *operation, id responseObject))success
                              failure:(void (^)(AFHTTPRequestOperation *operation, NSError *error))failure
{
    // completionBlock is manually nilled out in AFURLConnectionOperation to break the retain cycle.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"
#pragma clang diagnostic ignored "-Wgnu"
    // 直接覆写NSOperation的completionBlock，当isFinished为YES的时候会调用
    // 这里其实是循环引用的，self->completionBlock->self，不这样的话传到外面block里的operation就会释放掉
    self.completionBlock = ^{
        if (self.completionGroup) {
            dispatch_group_enter(self.completionGroup);
        }

        dispatch_async(http_request_operation_processing_queue(), ^{
            if (self.error) {
                if (failure) {
                    // 回到主线程
                    dispatch_group_async(self.completionGroup ?: http_request_operation_completion_group(), self.completionQueue ?: dispatch_get_main_queue(), ^{
                        failure(self, self.error);
                    });
                }
            } else {
                id responseObject = self.responseObject;
                if (self.error) {
                    if (failure) {
                        // 回到主线程
                        dispatch_group_async(self.completionGroup ?: http_request_operation_completion_group(), self.completionQueue ?: dispatch_get_main_queue(), ^{
                            failure(self, self.error);
                        });
                    }
                } else {
                    if (success) {
                        // 回到主线程
                        dispatch_group_async(self.completionGroup ?: http_request_operation_completion_group(), self.completionQueue ?: dispatch_get_main_queue(), ^{
                            success(self, responseObject);
                        });
                    }
                }
            }

            if (self.completionGroup) {
                dispatch_group_leave(self.completionGroup);
            }
        });
    };
#pragma clang diagnostic pop
}

#pragma mark - AFURLRequestOperation

// 暂停操作
- (void)pause {
    // 调用父类
    [super pause];

    u_int64_t offset = 0;
    if ([self.outputStream propertyForKey:NSStreamFileCurrentOffsetKey]) {
        // 读取当前的offset
        offset = [(NSNumber *)[self.outputStream propertyForKey:NSStreamFileCurrentOffsetKey] unsignedLongLongValue];
    } else {
        offset = [(NSData *)[self.outputStream propertyForKey:NSStreamDataWrittenToMemoryStreamKey] length];
    }

    NSMutableURLRequest *mutableURLRequest = [self.request mutableCopy];
    // 如果http请求含有headers并且服务端支持ETag
    if ([self.response respondsToSelector:@selector(allHeaderFields)] && [[self.response allHeaderFields] valueForKey:@"ETag"]) {
        // 设置If-Range头，设置ETag来缓存
        // If-Range头部需配合Range，如果没有Range参数，则If-Range会被视为无效
        // 如果If-Range匹配上，那么客户端已经存在的部分是有效的，服务器将返回缺失部分，也就是Range里指定的，然后返回206，否则证明客户端的部分已无效（可能已经更改），那么服务器将整个实体内容全部返回给客户端，同时返回200OK
        // 格式：If-Range: "df6b0-b4a-3be1b5e1"
        [mutableURLRequest setValue:[[self.response allHeaderFields] valueForKey:@"ETag"] forHTTPHeaderField:@"If-Range"];
    }
    // 设置range头，以便下次请求从offset处开始
    [mutableURLRequest setValue:[NSString stringWithFormat:@"bytes=%llu-", offset] forHTTPHeaderField:@"Range"];
    self.request = mutableURLRequest;
}

#pragma mark - NSSecureCoding

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (id)initWithCoder:(NSCoder *)decoder {
    self = [super initWithCoder:decoder];
    if (!self) {
        return nil;
    }

    self.responseSerializer = [decoder decodeObjectOfClass:[AFHTTPResponseSerializer class] forKey:NSStringFromSelector(@selector(responseSerializer))];

    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [super encodeWithCoder:coder];

    [coder encodeObject:self.responseSerializer forKey:NSStringFromSelector(@selector(responseSerializer))];
}

#pragma mark - NSCopying

- (id)copyWithZone:(NSZone *)zone {
    AFHTTPRequestOperation *operation = [super copyWithZone:zone];

    operation.responseSerializer = [self.responseSerializer copyWithZone:zone];
    operation.completionQueue = self.completionQueue;
    operation.completionGroup = self.completionGroup;

    return operation;
}

@end
