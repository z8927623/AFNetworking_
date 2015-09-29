// AFURLConnectionOperation.m
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

#import "AFURLConnectionOperation.h"

#if defined(__IPHONE_OS_VERSION_MIN_REQUIRED)
#import <UIKit/UIKit.h>
#endif

// AF 2.0只支持ARC下工作
#if !__has_feature(objc_arc)
#error AFNetworking must be built with ARC.
// You can turn on ARC for only AFNetworking files by adding -fobjc-arc to the build phase for each of its files.
#endif

// 操作队列枚举类型
typedef NS_ENUM(NSInteger, AFOperationState) {
    AFOperationPausedState      = -1,
    AFOperationReadyState       = 1,
    AFOperationExecutingState   = 2,
    AFOperationFinishedState    = 3,
};

// 创建GCD组
// 单例
static dispatch_group_t url_request_operation_completion_group() {
    static dispatch_group_t af_url_request_operation_completion_group;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        af_url_request_operation_completion_group = dispatch_group_create();
    });

    return af_url_request_operation_completion_group;
}

// 创建GCD并发队列
// 单例
static dispatch_queue_t url_request_operation_completion_queue() {
    static dispatch_queue_t af_url_request_operation_completion_queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        af_url_request_operation_completion_queue = dispatch_queue_create("com.alamofire.networking.operation.queue", DISPATCH_QUEUE_CONCURRENT );
    });

    return af_url_request_operation_completion_queue;
}

static NSString * const kAFNetworkingLockName = @"com.alamofire.networking.operation.lock";

// 定义操作开始和完成通知（完成包括操作成功、失败、取消）
NSString * const AFNetworkingOperationDidStartNotification = @"com.alamofire.networking.operation.start";
NSString * const AFNetworkingOperationDidFinishNotification = @"com.alamofire.networking.operation.finish";

// progress block
typedef void (^AFURLConnectionOperationProgressBlock)(NSUInteger bytes, long long totalBytes, long long totalBytesExpected);

typedef void (^AFURLConnectionOperationAuthenticationChallengeBlock)(NSURLConnection *connection, NSURLAuthenticationChallenge *challenge);

// cache  block
typedef NSCachedURLResponse * (^AFURLConnectionOperationCacheResponseBlock)(NSURLConnection *connection, NSCachedURLResponse *cachedResponse);

// redirect block
typedef NSURLRequest * (^AFURLConnectionOperationRedirectResponseBlock)(NSURLConnection *connection, NSURLRequest *request, NSURLResponse *redirectResponse);
typedef void (^AFURLConnectionOperationBackgroundTaskCleanupBlock)();

// 将枚举状态改为NSOperation定义的
static inline NSString * AFKeyPathFromOperationState(AFOperationState state) {
    switch (state) {
        case AFOperationReadyState:
            return @"isReady";
        case AFOperationExecutingState:
            return @"isExecuting";
        case AFOperationFinishedState:
            return @"isFinished";
        case AFOperationPausedState:
            return @"isPaused";
        default: {
            // 走不到的代码
            // 消除警告，不然pod lib lint通不过
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunreachable-code"
            return @"state";
#pragma clang diagnostic pop
        }
    }
}

/**
 * 判断状态转变是否是合理的，即规定可以从什么状态切换到什么状态
 *
 * @param fromState 状态
 * @param toState 要转变的状态
 * @param isCancelled 当前状态是否是取消的
 */
static inline BOOL AFStateTransitionIsValid(AFOperationState fromState, AFOperationState toState, BOOL isCancelled) {
    switch (fromState) {
        case AFOperationReadyState:     // from state is ready
            switch (toState) {
                // ready状态能向paused和executing状态转变
                case AFOperationPausedState:
                case AFOperationExecutingState:
                    return YES;
                    // ready状态向完成转变的话只能是调用cancel了
                case AFOperationFinishedState:
                    return isCancelled;
                default:
                    return NO;
            }
        case AFOperationExecutingState:     // executing，执行中有暂停和完成状态
            switch (toState) {
                case AFOperationPausedState:
                case AFOperationFinishedState:
                    return YES;
                default:
                    return NO;
            }
        case AFOperationFinishedState:      // 当前已经完成，不能设置状态
            return NO;
        case AFOperationPausedState:       // 当前为暂停
            // 暂停状态只能往ready状态转
            return toState == AFOperationReadyState;
        default: {
             // 消除警告，不然pod lib lint通不过
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunreachable-code"
            switch (toState) {
                case AFOperationPausedState:
                case AFOperationReadyState:
                case AFOperationExecutingState:
                case AFOperationFinishedState:
                    return YES;
                default:
                    return NO;
            }
        }
#pragma clang diagnostic pop
    }
}

@interface AFURLConnectionOperation ()
// 请求状态
@property (readwrite, nonatomic, assign) AFOperationState state;
// 递归锁，防止在一个线程里多次多次lock造成死锁
@property (readwrite, nonatomic, strong) NSRecursiveLock *lock;
// connection
@property (readwrite, nonatomic, strong) NSURLConnection *connection;
// request
@property (readwrite, nonatomic, strong) NSURLRequest *request;
// response
@property (readwrite, nonatomic, strong) NSURLResponse *response;
// error
@property (readwrite, nonatomic, strong) NSError *error;
// response related
@property (readwrite, nonatomic, strong) NSData *responseData;
@property (readwrite, nonatomic, copy) NSString *responseString;
@property (readwrite, nonatomic, assign) NSStringEncoding responseStringEncoding;
// 当前已经读取的数目
@property (readwrite, nonatomic, assign) long long totalBytesRead;
// 执行后台任务清理的block
@property (readwrite, nonatomic, copy) AFURLConnectionOperationBackgroundTaskCleanupBlock backgroundTaskCleanup;

// 上传进度block
@property (readwrite, nonatomic, copy) AFURLConnectionOperationProgressBlock uploadProgress;
// 下载进度block
@property (readwrite, nonatomic, copy) AFURLConnectionOperationProgressBlock downloadProgress;

@property (readwrite, nonatomic, copy) AFURLConnectionOperationAuthenticationChallengeBlock authenticationChallenge;
@property (readwrite, nonatomic, copy) AFURLConnectionOperationCacheResponseBlock cacheResponse;
@property (readwrite, nonatomic, copy) AFURLConnectionOperationRedirectResponseBlock redirectResponse;

// 几个操作
- (void)operationDidStart;
- (void)finish;
- (void)cancelConnection;
@end

@implementation AFURLConnectionOperation
@synthesize outputStream = _outputStream;

#pragma mark - LifeCycle

+ (void)networkRequestThreadEntryPoint:(id)__unused object {
    // 必须创建自己的自动释放池，因为对主线程的autorelease pool不具备访问权
    @autoreleasepool {
        // 设置线程别名
        [[NSThread currentThread] setName:@"AFNetworking"];

        NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
        // 设置port作为input source输入源
        [runLoop addPort:[NSMachPort port] forMode:NSDefaultRunLoopMode];
        // 开启子线程的RunLoop
        [runLoop run];
    }
}

// 该方法为单例
// 在等待请求时只有一个Thread, 然后在这个Thread上启动一个runLoop监听NSURLConnection的NSMachPort类型源
// start、cancel、pause操作是在该线程操作的
// 该线程并不是最终访问网络并拉取数据的线程，真正的下载数据是NSURLConnection统一调度的
+ (NSThread *)networkRequestThread {
    static NSThread *_networkRequestThread = nil;
    static dispatch_once_t oncePredicate;
    dispatch_once(&oncePredicate, ^{
        // 线程中再另开一个线程
        _networkRequestThread = [[NSThread alloc] initWithTarget:self selector:@selector(networkRequestThreadEntryPoint:) object:nil];
        // 运行thread
        [_networkRequestThread start];
    });

    return _networkRequestThread;
}

// 初始化方法，供外部调用
- (instancetype)initWithRequest:(NSURLRequest *)urlRequest {
    NSParameterAssert(urlRequest);

    self = [super init];
    if (!self) {
		return nil;
    }

    // 设置默认状态为ready
    _state = AFOperationReadyState;

    // 初始化递归锁名
    self.lock = [[NSRecursiveLock alloc] init];
    // 设置递归锁
    self.lock.name = kAFNetworkingLockName;
    // 默认设置runloop运行模式为NSRunLoopCommonModes
    self.runLoopModes = [NSSet setWithObject:NSRunLoopCommonModes];

    self.request = urlRequest;

    self.shouldUseCredentialStorage = YES;

    self.securityPolicy = [AFSecurityPolicy defaultPolicy];

    return self;
}

- (instancetype)init NS_UNAVAILABLE
{
    return nil;
}

// NSOperationQueue获得了NSOperation的所有权，操作结束后负责释放它。
- (void)dealloc {
    if (_outputStream) {
        // 关闭输出流
        [_outputStream close];
        _outputStream = nil;
    }
    
    // 后台任务清理
    if (_backgroundTaskCleanup) {
        // 执行后台任务清理的block
        _backgroundTaskCleanup();
    }
}

#pragma mark -
#pragma mark - Response setters and getters
- (void)setResponseData:(NSData *)responseData {
    // 注意要加锁，互斥访问，防止资源竞争
    [self.lock lock];
    if (!responseData) {
        _responseData = nil;
    } else {
        _responseData = [NSData dataWithBytes:responseData.bytes length:responseData.length];
    }
    [self.lock unlock];
}

- (NSString *)responseString {
    [self.lock lock];
    // response: NSURLResponse
    // 这里必须保证self.response不为空
    if (!_responseString && self.response && self.responseData) {
        self.responseString = [[NSString alloc] initWithData:self.responseData encoding:self.responseStringEncoding];
    }
    [self.lock unlock];

    return _responseString;
}

- (NSStringEncoding)responseStringEncoding {
    [self.lock lock];
    if (!_responseStringEncoding && self.response) {
        NSStringEncoding stringEncoding = NSUTF8StringEncoding;
        if (self.response.textEncodingName) {
            // 获取NSURLResponse编码类型
            CFStringEncoding IANAEncoding = CFStringConvertIANACharSetNameToEncoding((__bridge CFStringRef)self.response.textEncodingName);
            if (IANAEncoding != kCFStringEncodingInvalidId) {
                stringEncoding = CFStringConvertEncodingToNSStringEncoding(IANAEncoding);
            }
        }

        self.responseStringEncoding = stringEncoding;
    }
    [self.lock unlock];

    return _responseStringEncoding;
}

#pragma mark - Stream getter and setter
// 输入流getter
- (NSInputStream *)inputStream {
    return self.request.HTTPBodyStream;
}

// 输入流setter
- (void)setInputStream:(NSInputStream *)inputStream {
    NSMutableURLRequest *mutableRequest = [self.request mutableCopy];
    // 设置http请求体输入流
    mutableRequest.HTTPBodyStream = inputStream;
    self.request = mutableRequest;
}

// 输出流getter
- (NSOutputStream *)outputStream {
    if (!_outputStream) {
        self.outputStream = [NSOutputStream outputStreamToMemory];
    }

    return _outputStream;
}

// 输入流setter
- (void)setOutputStream:(NSOutputStream *)outputStream {
    // 上锁
    [self.lock lock];
    if (outputStream != _outputStream) {
        if (_outputStream) {
            // 先关闭
            [_outputStream close];
        }

        _outputStream = outputStream;
    }
    [self.lock unlock];
}

#pragma mark - 
#pragma mark - Background task

// 设置是否需要进入后台取消操作
// 判断版本是否支持，后台任务4.0后才支持
// 注意是主线程同步调用的
#if defined(__IPHONE_OS_VERSION_MIN_REQUIRED)
- (void)setShouldExecuteAsBackgroundTaskWithExpirationHandler:(void (^)(void))handler {
    [self.lock lock];
    if (!self.backgroundTaskCleanup) {   // 没有定义后台清理任务的block
        UIApplication *application = [UIApplication sharedApplication];
        UIBackgroundTaskIdentifier __block backgroundTaskIdentifier = UIBackgroundTaskInvalid;
        // 弱引用
        __weak __typeof(self)weakSelf = self;
        
        // 定义这里是结束后台任务block
        self.backgroundTaskCleanup = ^(){
            // 结束后台任务
            if (backgroundTaskIdentifier != UIBackgroundTaskInvalid) {
                [[UIApplication sharedApplication] endBackgroundTask:backgroundTaskIdentifier];
                backgroundTaskIdentifier = UIBackgroundTaskInvalid;
            }
        };
        
        // 开启后台任务
        backgroundTaskIdentifier = [application beginBackgroundTaskWithExpirationHandler:^{
            // 强引用
            // 一旦进入block执行，就不允许self在这个执行过程中释放
            __strong __typeof(weakSelf)strongSelf = weakSelf;
            // 执行需要在后台执行的一些任务
            if (handler) {
                handler();
            }

            if (strongSelf) {
                // 进入后台后取消请求
                [strongSelf cancel];
                // 操作完成后结束后台任务
                strongSelf.backgroundTaskCleanup();
            }
        }];
    }
    [self.lock unlock];
}
#endif

#pragma mark -
#pragma mark - pause and resume

// 覆写状态
- (void)setState:(AFOperationState)state {
    // 判断状态改变是否是合理的
    // self.state：当前状态   state：要转变的状态
    if (!AFStateTransitionIsValid(self.state, state, [self isCancelled])) {
        return;
    }
    // 上锁
    [self.lock lock];
    NSString *oldStateKey = AFKeyPathFromOperationState(self.state);
    NSString *newStateKey = AFKeyPathFromOperationState(state);

    // 手动发送KVO通知来告诉NSOperationQueue当前NSOperation的状态
    [self willChangeValueForKey:newStateKey];
    [self willChangeValueForKey:oldStateKey];
    // 改变状态
    _state = state;
    [self didChangeValueForKey:oldStateKey];
    [self didChangeValueForKey:newStateKey];
    [self.lock unlock];
}
// 暂停操作
- (void)pause {
    // 已经暂停或完成或取消状态，取消操作无效
    if ([self isPaused] || [self isFinished] || [self isCancelled]) {
        return;
    }

    [self.lock lock];
    if ([self isExecuting]) {   // 正在执行
        // start跳到networkRequestThread线程中执行
        [self performSelector:@selector(operationDidPause) onThread:[[self class] networkRequestThread] withObject:nil waitUntilDone:NO modes:[self.runLoopModes allObjects]];

        // 到主线程发送操作完成通知
        dispatch_async(dispatch_get_main_queue(), ^{
            NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
            [notificationCenter postNotificationName:AFNetworkingOperationDidFinishNotification object:self];
        });
    }
    // 修改状态为isPaused
    self.state = AFOperationPausedState;
    [self.lock unlock];
}

// 暂停操作取消了连接，
- (void)operationDidPause {
    [self.lock lock];
    // 取消连接，下次继续就新建一个连接，如果服务端支持If-Range则通过range设置offset
    [self.connection cancel];
    [self.lock unlock];
}

// 是否暂停
- (BOOL)isPaused {
    return self.state == AFOperationPausedState;
}

// 继续
- (void)resume {
    if (![self isPaused]) {  // 如果不是暂停状态，此操作无效
        return;
    }

    [self.lock lock];
    // 修改状态为isReady
    self.state = AFOperationReadyState;
    // resume操作，调用start，新起连接
    [self start];
    [self.lock unlock];
}

#pragma mark -
#pragma mark - block setters

// 上传block
- (void)setUploadProgressBlock:(void (^)(NSUInteger bytesWritten, long long totalBytesWritten, long long totalBytesExpectedToWrite))block {
    self.uploadProgress = block;
}
// 下载block
- (void)setDownloadProgressBlock:(void (^)(NSUInteger bytesRead, long long totalBytesRead, long long totalBytesExpectedToRead))block {
    self.downloadProgress = block;
}
// 将会发送block
- (void)setWillSendRequestForAuthenticationChallengeBlock:(void (^)(NSURLConnection *connection, NSURLAuthenticationChallenge *challenge))block {
    self.authenticationChallenge = block;
}
// 缓存block
- (void)setCacheResponseBlock:(NSCachedURLResponse * (^)(NSURLConnection *connection, NSCachedURLResponse *cachedResponse))block {
    self.cacheResponse = block;
}
// 重连接block
- (void)setRedirectResponseBlock:(NSURLRequest * (^)(NSURLConnection *connection, NSURLRequest *request, NSURLResponse *redirectResponse))block {
    self.redirectResponse = block;
}


#pragma mark - 
#pragma mark - Override NSOperation methods

// 表示已准备好执行
- (BOOL)isReady {
    return self.state == AFOperationReadyState && [super isReady];
}

// 表示正在执行
- (BOOL)isExecuting {
    return self.state == AFOperationExecutingState;
}

// 表示操作已完成，这里有可能是取消了操作或者失败或者完成，因为这些事件发生时isFinished状态也是为YES
// 另外，操作中如果有依赖的话，必须发出合适的“isFinished”KVO通知，否则依赖你的NSOperation就无法正常执行
- (BOOL)isFinished {
    return self.state == AFOperationFinishedState;
}

// 表示并发
- (BOOL)isConcurrent {
    return YES;
}

// 重写start方法，该方法在NSOperation放入NSOperationQueue之后执行
// 当实现了start方法时，默认会执行start方法，而不执行main方法
// main方法一般用来执行同步任务
- (void)start {
    // 注意上锁
    [self.lock lock];
    // 轮询[self isCancelled]的必要性
    if ([self isCancelled]) {   // 判断是否取消，可能operation调用了cancel
        // 取消操作
        [self performSelector:@selector(cancelConnection) onThread:[[self class] networkRequestThread] withObject:nil waitUntilDone:NO modes:[self.runLoopModes allObjects]];
    } else if ([self isReady]) {  // ready状态，表示已可以执行
        // 修改状态为isExecuting
        self.state = AFOperationExecutingState;
        // 在公共独立子线程配合Run Loop来实现管理网络请求，因此查看堆栈会发现实际上只有一个AFNetworking的线程
        [self performSelector:@selector(operationDidStart) onThread:[[self class] networkRequestThread] withObject:nil waitUntilDone:NO modes:[self.runLoopModes allObjects]];
    }
    // 解锁
    [self.lock unlock];
}

// 重写cancel方法，调用NSOperation的Cancel方法后执行
// 如果一个操作并没有开始，调用cancel方法，操作会被取消，并从队列中移除。如果一个操作已经在执行，这就要通过检查isCancelled属性然后停止它所做的工作
// 如果NSOperation不在队列中执行的，cancel后它的状态马上会变成isFinished
- (void)cancel {
    [self.lock lock];
    // 如果状态没被标记为完成（成功、失败或取消）和取消   这里的状态标记都是自己设置的
    if (![self isFinished] && ![self isCancelled]) {
        // 调用父类cancel
        [super cancel];
        
        // 如果还在执行，start已经调用，connection已经被初始化，但此时还未完成，isFinished = NO，isExecuting = YES
        if ([self isExecuting]) {
            // 取消NSURLConnection操作并设置状态为isFinished
            [self performSelector:@selector(cancelConnection) onThread:[[self class] networkRequestThread] withObject:nil waitUntilDone:NO modes:[self.runLoopModes allObjects]];
        }
    }
    [self.lock unlock];
}

// 设置完成block，该方法在AFHTTPRequestOperation的setCompletionBlockWithSuccess中调用
// completionBlock在isFinished = YES的时候调用
- (void)setCompletionBlock:(void (^)(void))block {
    // lock
    [self.lock lock];
    if (!block) {
        // 手动设置为nil
        [super setCompletionBlock:nil];
    } else {
        // 弱引用，防止循环引用
        __weak __typeof(self)weakSelf = self;
        // 调用super block
        [super setCompletionBlock:^ {
            // 强引用，防止block执行的时候self已经被释放
            __strong __typeof(weakSelf)strongSelf = weakSelf;
            
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wgnu"
            dispatch_group_t group = strongSelf.completionGroup ?: url_request_operation_completion_group();
            // queue默认为主线程
            dispatch_queue_t queue = strongSelf.completionQueue ?: dispatch_get_main_queue();
#pragma clang diagnostic pop
            // 调用单个operation完成的操作block
            dispatch_group_async(group, queue, ^{
                // 执行AFHTTPRequestOperation中定义的completionBlockblock的内容
                block();
            });
            
            // block完成后，调用单个operation完成的通知block，url_request_operation_completion_queue为concurrent queue
            dispatch_group_notify(group, url_request_operation_completion_queue(), ^{
                // 手动设置为nil，打破AFHTTPRequestOperation中的循环引用
                [strongSelf setCompletionBlock:nil];
            });
        }];
    }
    [self.lock unlock];
}


#pragma mark - Actions
// 操作被添加到NSOperationQueue后start后的后续操作
- (void)operationDidStart {
    // 上锁
    [self.lock lock];
    // 判断是否已取消
    if (![self isCancelled]) {
        // 在新起的名为AFNetworking的线程中初始化NSURLConnection
        // 如果不在networkRequestThread线程中，必须开启operation的runloop去接收异步回调事件，因为后台线程runloop默认是不启动的
        // 就是说代码执行完，线程就结束被回收了，因此NSURLConnection的代理operation就是nil，因此connection还在执行，但是收不到回调
        self.connection = [[NSURLConnection alloc] initWithRequest:self.request delegate:self startImmediately:NO];

        NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
        for (NSString *runLoopMode in self.runLoopModes) {
            // 绑定事件源
            // 指定connection运行模式为在NSRunLoopCommonModes
            [self.connection scheduleInRunLoop:runLoop forMode:runLoopMode];
            // 指定stream运行模式为在NSRunLoopCommonModes
            [self.outputStream scheduleInRunLoop:runLoop forMode:runLoopMode];
        }

        // 打开输出流
        [self.outputStream open];
        // 开始执行connection操作
        [self.connection start];
    }
    // 解锁
    [self.lock unlock];

    // 到主队列中发送操作开始通知
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:AFNetworkingOperationDidStartNotification object:self];
    });
}

// 操作完成（成功、失败、取消）后的后续操作
- (void)finish {
    // 注意上锁
    [self.lock lock];
    // 状态设置为完成，调用setter方法
    self.state = AFOperationFinishedState;
    [self.lock unlock];

    // 到主队列中发送操作完成通知
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:AFNetworkingOperationDidFinishNotification object:self];
    });
}

// 操作取消后的后续操作
- (void)cancelConnection {
    // 构造NSError
    NSDictionary *userInfo = nil;
    if ([self.request URL]) {
        userInfo = @{NSURLErrorFailingURLErrorKey : [self.request URL]};
    }
    NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:userInfo];

    if (![self isFinished]) {   // 如果状态还没有被标志为完成，在队列中的operation cancel后状态不会马上变为isFinished
        if (self.connection) {  // start已经调用，connection已经被初始化，但此时还未完成，isFinished = NO，
            // 取消NSURLConnection操作
            [self.connection cancel];
            // 发送connection:didFailWithError:消息，错误消息会显示操作被取消
            // connection:didFailWithError里会调用[self finish]
            [self performSelector:@selector(connection:didFailWithError:) withObject:self.connection withObject:error];
        } else {
            // Accommodate race condition where `self.connection` has not yet been set before cancellation
            
            // 一种情况是取消的时候NSURLConnection还不存在，比如一个队列有5个操作但是并发数只有2个，它恰好是第3个，因此还是ready状态，这时候start方法就没有调用，所以self.connection并不存在
            // 这个时候如果调用了cancel或者cancelAllOperations操作，发送完成操作，其实并没有开始
            self.error = error;
            [self finish];
        }
    }
}

#pragma mark -

// 批量request
+ (NSArray *)batchOfRequestOperations:(NSArray *)operations
                        progressBlock:(void (^)(NSUInteger numberOfFinishedOperations, NSUInteger totalNumberOfOperations))progressBlock
                      completionBlock:(void (^)(NSArray *operations))completionBlock
{
    if (!operations || [operations count] == 0) {
        return @[[NSBlockOperation blockOperationWithBlock:^{
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completionBlock) {
                    completionBlock(@[]);
                }
            });
        }]];
    }

    __block dispatch_group_t group = dispatch_group_create();
    // 操作完成
    NSBlockOperation *batchedOperation = [NSBlockOperation blockOperationWithBlock:^{
        // 来到主线程调用操作最后一个操作完成block
        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            if (completionBlock) {
                completionBlock(operations);
            }
        });
    }];

    // 遍历操作数据
    for (AFURLConnectionOperation *operation in operations) {
        // 赋值给成员dispatch_group_t
        operation.completionGroup = group;
        // 拷贝completionBlock
        void (^originalCompletionBlock)(void) = [operation.completionBlock copy];
        // weak retain
        __weak __typeof(operation)weakOperation = operation;
        // 这里调用覆写的setCompletionBlock，这里是每个operation完成的block
        operation.completionBlock = ^{
            // strong retain
            __strong __typeof(weakOperation)strongOperation = weakOperation;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wgnu"
            dispatch_queue_t queue = strongOperation.completionQueue ?: dispatch_get_main_queue();
#pragma clang diagnostic pop
            dispatch_group_async(group, queue, ^{
                if (originalCompletionBlock) {
                    originalCompletionBlock();
                }
                // 返回已经完成的个数，数组还能这么用！！
                NSUInteger numberOfFinishedOperations = [[operations indexesOfObjectsPassingTest:^BOOL(id op, NSUInteger __unused idx,  BOOL __unused *stop) {
                    // 条件为isFinished
                    return [op isFinished];
                }] count];

                if (progressBlock) {
                    // 总体进度block = 完成的operation数/总operation数
                    progressBlock(numberOfFinishedOperations, [operations count]);
                }
                // 完成后一定要leave group，和dispatch_group_enter配对
                dispatch_group_leave(group);
            });
        };
        // enter group
        dispatch_group_enter(group);
        // 添加依赖，后一个依赖前一个，即操作顺序按照数据的顺序开始，前一个完成后下一个才能开始
        [batchedOperation addDependency:operation];
    }

    // 最后增加完成block
    return [operations arrayByAddingObject:batchedOperation];
}


#pragma mark - Override description

- (NSString *)description {
    [self.lock lock];
    NSString *description = [NSString stringWithFormat:@"<%@: %p, state: %@, cancelled: %@ request: %@, response: %@>", NSStringFromClass([self class]), self, AFKeyPathFromOperationState(self.state), ([self isCancelled] ? @"YES" : @"NO"), self.request, self.response];
    [self.lock unlock];
    return description;
}

#pragma mark - NSURLConnectionDelegate

// 1
// 设置URL重定向时执行的block
// 在执行请求之前调用，处理网络协议的重定向
- (NSURLRequest *)connection:(NSURLConnection *)connection
             willSendRequest:(NSURLRequest *)request
            redirectResponse:(NSURLResponse *)redirectResponse
{
    if (self.redirectResponse) {
        return self.redirectResponse(connection, request, redirectResponse);
    } else {
        return request;
    }
}

// 2
// 是否使用凭证存储来认证连接
- (BOOL)connectionShouldUseCredentialStorage:(NSURLConnection __unused *)connection {
    return self.shouldUseCredentialStorage;
}

// 3（HTTPS）
// 告诉协议，连接（connection）将会为身份认证询问发送一个请求
// 该消息之后会发送connectionShouldUseCredentialStorage消息
- (void)connection:(NSURLConnection *)connection
willSendRequestForAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
{
    if (self.authenticationChallenge) {
        self.authenticationChallenge(connection, challenge);
        return;
    }
    
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        if ([self.securityPolicy evaluateServerTrust:challenge.protectionSpace.serverTrust forDomain:challenge.protectionSpace.host]) {
            NSURLCredential *credential = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
            [[challenge sender] useCredential:credential forAuthenticationChallenge:challenge];
        } else {
            [[challenge sender] cancelAuthenticationChallenge:challenge];
        }
    } else {
        if ([challenge previousFailureCount] == 0) {
            if (self.credential) {
                [[challenge sender] useCredential:self.credential forAuthenticationChallenge:challenge];
            } else {
                [[challenge sender] continueWithoutCredentialForAuthenticationChallenge:challenge];
            }
        } else {
            [[challenge sender] continueWithoutCredentialForAuthenticationChallenge:challenge];
        }
    }
}

// 4（POST）
// Sent as the body (message data) of a request is transmitted (such as in an http POST request).
// POST请求接收数据流
- (void)connection:(NSURLConnection __unused *)connection
   didSendBodyData:(NSInteger)bytesWritten
 totalBytesWritten:(NSInteger)totalBytesWritten
totalBytesExpectedToWrite:(NSInteger)totalBytesExpectedToWrite
{
    // 回到主线程调用progress block
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.uploadProgress) {
            self.uploadProgress((NSUInteger)bytesWritten, totalBytesWritten, totalBytesExpectedToWrite);
        }
    });
}

// 5
// 当服务端提供了有效的数据来创建NSURLResponse对象时，代理会收到connection:didReceiveResponse:消息。
// 这个代理方法会检查NSURLResponse对象并确认数据的content-type，MIME类型，文件 名和其它元数据。
// 需要注意的是，对于单个连接，我们可能会接多次收到connection:didReceiveResponse:消息，这种情况发生在
// 响应是多重MIME编码的情况下，每次代理接收到connection:didReceiveResponse:时，应该重设进度标识
// 并丢弃之前接收到的数据。
- (void)connection:(NSURLConnection __unused *)connection
didReceiveResponse:(NSURLResponse *)response
{
    // 赋值NSURLResponse
    self.response = response;
}

// 6
// 代理会定期接收到connection:didReceiveData:消息，该消息用于接收服务端返回的数据实体。该方法负责存储数据。
// 我们也可以用这个方法提供进度信息，这种情况下，我们需要在connection:didReceiveResponse:方法中
// 调用响应对象的expectedContentLength方法来获取数据的总长度。
- (void)connection:(NSURLConnection __unused *)connection
    didReceiveData:(NSData *)data
{
    // data长度
    NSUInteger length = [data length];
    while (YES) {
        NSInteger totalNumberOfBytesWritten = 0;
        if ([self.outputStream hasSpaceAvailable]) {
            const uint8_t *dataBuffer = (uint8_t *)[data bytes];

            NSInteger numberOfBytesWritten = 0;
            // 循环读取数据流
            while (totalNumberOfBytesWritten < (NSInteger)length) {
                numberOfBytesWritten = [self.outputStream write:&dataBuffer[(NSUInteger)totalNumberOfBytesWritten] maxLength:(length - (NSUInteger)totalNumberOfBytesWritten)];
                if (numberOfBytesWritten == -1) {
                    break;
                }

                totalNumberOfBytesWritten += numberOfBytesWritten;
            }

            break;
        }
        
        // 流错误，取消connection
        if (self.outputStream.streamError) {
            [self.connection cancel];
            // 发送错误消息
            [self performSelector:@selector(connection:didFailWithError:) withObject:self.connection withObject:self.outputStream.streamError];
            return;
        }
    }

    // 回到主队列更新进度
    dispatch_async(dispatch_get_main_queue(), ^{
        self.totalBytesRead += (long long)length;

        // 下载进度条
        if (self.downloadProgress) {
            self.downloadProgress(length, self.totalBytesRead, self.response.expectedContentLength);
        }
    });
}

// 7
// 该可选方法向委托提供了一种方式来检测与修改协议控制器所缓存的响应
- (NSCachedURLResponse *)connection:(NSURLConnection *)connection
                  willCacheResponse:(NSCachedURLResponse *)cachedResponse
{
    if (self.cacheResponse) {   // 定义了缓存block
        return self.cacheResponse(connection, cachedResponse);
    } else {
        // 已经取消，nil
        if ([self isCancelled]) {
            return nil;
        }
        
        return cachedResponse;
    }
}

// 8
// 加载完成
- (void)connectionDidFinishLoading:(NSURLConnection __unused *)connection {
    // 从输出流NSOutputStream中取得NSData
    self.responseData = [self.outputStream propertyForKey:NSStreamDataWrittenToMemoryStreamKey];

    // 关闭输出流
    [self.outputStream close];
    if (self.responseData) {
        // 将输出流置为nil
        self.outputStream = nil;
    }

    // 将NSURLConnection置为nil
    self.connection = nil;

    // 完成后续操作
    [self finish];
}

// 8
// 失败
- (void)connection:(NSURLConnection __unused *)connection
  didFailWithError:(NSError *)error
{
    // 赋值error
    self.error = error;

    // 关闭输出流
    [self.outputStream close];
    if (self.responseData) {
        // 将输出流置为nil
        self.outputStream = nil;
    }

    // 将NSURLConnection置为nil
    self.connection = nil;

    // 完成后续操作
    [self finish];
}

#pragma mark - NSSecureCoding

// 归档

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (id)initWithCoder:(NSCoder *)decoder {
    NSURLRequest *request = [decoder decodeObjectOfClass:[NSURLRequest class] forKey:NSStringFromSelector(@selector(request))];

    self = [self initWithRequest:request];
    if (!self) {
        return nil;
    }

    self.state = [[decoder decodeObjectOfClass:[NSNumber class] forKey:NSStringFromSelector(@selector(state))] integerValue];
    self.response = [decoder decodeObjectOfClass:[NSHTTPURLResponse class] forKey:NSStringFromSelector(@selector(response))];
    self.error = [decoder decodeObjectOfClass:[NSError class] forKey:NSStringFromSelector(@selector(error))];
    self.responseData = [decoder decodeObjectOfClass:[NSData class] forKey:NSStringFromSelector(@selector(responseData))];
    self.totalBytesRead = [[decoder decodeObjectOfClass:[NSNumber class] forKey:NSStringFromSelector(@selector(totalBytesRead))] longLongValue];

    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [self pause];

    [coder encodeObject:self.request forKey:NSStringFromSelector(@selector(request))];

    switch (self.state) {
        case AFOperationExecutingState:
        case AFOperationPausedState:
            [coder encodeInteger:AFOperationReadyState forKey:NSStringFromSelector(@selector(state))];
            break;
        default:
            [coder encodeInteger:self.state forKey:NSStringFromSelector(@selector(state))];
            break;
    }

    [coder encodeObject:self.response forKey:NSStringFromSelector(@selector(response))];
    [coder encodeObject:self.error forKey:NSStringFromSelector(@selector(error))];
    [coder encodeObject:self.responseData forKey:NSStringFromSelector(@selector(responseData))];
    [coder encodeInt64:self.totalBytesRead forKey:NSStringFromSelector(@selector(totalBytesRead))];
}

#pragma mark - NSCopying

- (id)copyWithZone:(NSZone *)zone {
    AFURLConnectionOperation *operation = [(AFURLConnectionOperation *)[[self class] allocWithZone:zone] initWithRequest:self.request];

    operation.uploadProgress = self.uploadProgress;
    operation.downloadProgress = self.downloadProgress;
    operation.authenticationChallenge = self.authenticationChallenge;
    operation.cacheResponse = self.cacheResponse;
    operation.redirectResponse = self.redirectResponse;
    operation.completionQueue = self.completionQueue;
    operation.completionGroup = self.completionGroup;

    return operation;
}

@end
