/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDMemoryCache.h"
#import "SDImageCacheConfig.h"
#import "UIImage+MemoryCacheCost.h"
#import "SDInternalMacros.h"
#import <pthread.h>
#import <time.h>

static inline dispatch_queue_t SDMemoryCacheGetReleaseQueue(void) {
    return dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0);
}

@interface _SDLinkedMapNode : NSObject {
    @package
    __unsafe_unretained _SDLinkedMapNode *_prev;
    __unsafe_unretained _SDLinkedMapNode *_next;
    id _key;
    id _value;
    NSUInteger _cost;
    NSTimeInterval _time;
}

@end

@implementation _SDLinkedMapNode
@end

@interface _SDLinkedMap : NSObject {
    @package
    CFMutableDictionaryRef _dic;
    NSUInteger _totalCost;
    NSUInteger _totalCount;
    _SDLinkedMapNode *_head;
    _SDLinkedMapNode *_tail;
}

- (void)insertNodeAtHead:(_SDLinkedMapNode *)node;
- (void)bringNodeToHead:(_SDLinkedMapNode *)node;
- (void)removeNode:(_SDLinkedMapNode *)node;
- (_SDLinkedMapNode *)removeTailNode;
- (void)removeAll;

@end

@implementation _SDLinkedMap

- (instancetype)init {
    self = [super init];
    if (self) {
        _dic = CFDictionaryCreateMutable(CFAllocatorGetDefault(), 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    }
    return self;
}

- (void)dealloc {
    CFRelease(_dic);
}

- (void)insertNodeAtHead:(_SDLinkedMapNode *)node {
    CFDictionarySetValue(_dic, (__bridge const void *)(node->_key), (__bridge const void *)(node));
    _totalCost += node->_cost;
    _totalCount ++;
    if (_head) {
        node->_next = _head;
        _head->_prev = node;
        _head = node;
    } else {
        _head = _tail = node;
    }
}

- (void)bringNodeToHead:(_SDLinkedMapNode *)node {
    if (_head == node) return;
    
    if (_tail == node) {
        _tail = node->_prev;
        _tail->_next = nil;
    } else {
        node->_next->_prev = node->_prev;
        node->_prev->_next = node->_next;
    }
    node->_next = _head;
    node->_prev = nil;
    _head->_prev = node;
    _head = node;
}

- (void)removeNode:(_SDLinkedMapNode *)node {
    CFDictionaryRemoveValue(_dic, (__bridge const void *)(node->_key));
    _totalCost -= node->_cost;
    _totalCount --;
    if (node->_next) node->_next->_prev = node->_prev;
    if (node->_prev) node->_prev->_next = node->_next;
    if (_head == node) _head = node->_next;
    if (_tail == node) _tail = node->_prev;
}

- (_SDLinkedMapNode *)removeTailNode {
    if (!_tail) return nil;
    
    _SDLinkedMapNode *tail = _tail;
    CFDictionaryRemoveValue(_dic, (__bridge const void *)(_tail->_key));
    _totalCost -= _tail->_cost;
    _totalCount--;
    if (_head == _tail) {
        _head = _tail = nil;
    } else {
        _tail = _tail->_prev;
        _tail->_next = nil;
    }
    return tail;
}

- (void)removeAll {
    _totalCost = 0;
    _totalCount = 0;
    _head = nil;
    _tail = nil;
    
    if (CFDictionaryGetCount(_dic) > 0) {
        CFMutableDictionaryRef holder = _dic;
        _dic = CFDictionaryCreateMutable(CFAllocatorGetDefault(), 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        
        dispatch_async(SDMemoryCacheGetReleaseQueue(), ^{
            CFRelease(holder); // Hold and release in specified queue.
        });
    }
}

@end

@implementation SDMemoryCache {
    pthread_mutex_t _lock;
    _SDLinkedMap *_lru;
    dispatch_queue_t _queue;
    
    NSUInteger _countLimit;
    NSUInteger _costLimit;
    NSTimeInterval _ageLimit;
    NSTimeInterval _autoTrimInterval;
    BOOL _shouldRemoveAllObjectsOnMemoryWarning;
    BOOL _shouldRemoveAllObjectsWhenEnteringBackground;
}

- (void)_trimRecursively {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_autoTrimInterval * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [self _trimInBackground];
        [self _trimRecursively];
    });
}

- (void)_trimInBackground {
    dispatch_async(_queue, ^{
        [self _trimToCost:self->_costLimit];
        [self _trimToCount:self->_countLimit];
        [self _trimToAge:self->_ageLimit];
    });
}

- (void)_trimToCost:(NSUInteger)costLimit {
    BOOL finish = NO;
    pthread_mutex_lock(&_lock);
    if (costLimit == 0) {
        [_lru removeAll];
        finish = YES;
    } else if (_lru->_totalCost <= costLimit) {
        finish = YES;
    }
    pthread_mutex_unlock(&_lock);
    if (finish) return;
    
    NSMutableArray *holder = [NSMutableArray new];
    while (!finish) {
        if (pthread_mutex_trylock(&_lock) == 0) {
            if (_lru->_totalCost > costLimit) {
                _SDLinkedMapNode *node = [_lru removeTailNode];
                if (node) [holder addObject:node];
            } else {
                finish = YES;
            }
            pthread_mutex_unlock(&_lock);
        } else {
            usleep(10 * 1000); // 10 ms
        }
    }
    if (holder.count) {
        dispatch_async(SDMemoryCacheGetReleaseQueue(), ^{
            [holder count]; // Release in queue
        });
    }
}

- (void)_trimToCount:(NSUInteger)countLimit {
    BOOL finish = NO;
    pthread_mutex_lock(&_lock);
    if (countLimit == 0) {
        [_lru removeAll];
        finish = YES;
    } else if (_lru->_totalCount <= countLimit) {
        finish = YES;
    }
    pthread_mutex_unlock(&_lock);
    if (finish) return;
    
    NSMutableArray *holder = [NSMutableArray new];
    while (!finish) {
        if (pthread_mutex_trylock(&_lock) == 0) {
            if (_lru->_totalCount > countLimit) {
                _SDLinkedMapNode *node = [_lru removeTailNode];
                if (node) [holder addObject:node];
            } else {
                finish = YES;
            }
            pthread_mutex_unlock(&_lock);
        } else {
            usleep(10 * 1000); // 10 ms
        }
    }
    if (holder.count) {
        dispatch_async(SDMemoryCacheGetReleaseQueue(), ^{
            [holder count]; // Release in queue
        });
    }
}

- (void)_trimToAge:(NSTimeInterval)ageLimit {
    BOOL finish = NO;
    NSTimeInterval now = CACurrentMediaTime();
    pthread_mutex_lock(&_lock);
    if (ageLimit <= 0) {
        [_lru removeAll];
        finish = YES;
    } else if (!_lru->_tail || (now - _lru->_tail->_time) <= ageLimit) {
        finish = YES;
    }
    pthread_mutex_unlock(&_lock);
    if (finish) return;
    
    NSMutableArray *holder = [NSMutableArray new];
    while (!finish) {
        if (pthread_mutex_trylock(&_lock) == 0) {
            if (_lru->_tail && (now - _lru->_tail->_time) > ageLimit) {
                _SDLinkedMapNode *node = [_lru removeTailNode];
                if (node) [holder addObject:node];
            } else {
                finish = YES;
            }
            pthread_mutex_unlock(&_lock);
        } else {
            usleep(10 * 1000); // 10 ms
        }
    }
    if (holder.count) {
        dispatch_async(SDMemoryCacheGetReleaseQueue(), ^{
            [holder count]; // Release in queue
        });
    }
}

- (void)_appDidReceiveMemoryWarningNotification {
    if (_shouldRemoveAllObjectsOnMemoryWarning) {
        [self removeAllObjects];
    }
}

- (void)_appDidEnterBackgroundNotification {
    if (_shouldRemoveAllObjectsWhenEnteringBackground) {
        [self removeAllObjects];
    }
}

#pragma mark - Public Methods
- (instancetype)initWithConfig:(SDImageCacheConfig *)config {
    self = [super init];
    if (self) {
        _costLimit = config.maxMemoryCost;
        _countLimit = config.maxMemoryCount;
        _ageLimit = DBL_MAX;
        _autoTrimInterval = 5.0;
        _shouldRemoveAllObjectsOnMemoryWarning = YES;
        _shouldRemoveAllObjectsWhenEnteringBackground = YES;
        
        pthread_mutex_init(&_lock, NULL);
        _lru = [[_SDLinkedMap alloc] init];
        _queue = dispatch_queue_create("com.image.cache.memory", DISPATCH_QUEUE_SERIAL);
        
#if SD_UIKIT
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_appDidReceiveMemoryWarningNotification) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_appDidEnterBackgroundNotification) name:UIApplicationDidEnterBackgroundNotification object:nil];
#endif
        [self _trimRecursively];
    }
    return self;
}

- (void)dealloc {
#if SD_UIKIT
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
#endif
    [_lru removeAll];
    pthread_mutex_destroy(&_lock);
}

- (BOOL)containsObjectForKey:(id)key {
    if (!key) return NO;
    pthread_mutex_lock(&_lock);
    BOOL contains = CFDictionaryContainsKey(_lru->_dic, (__bridge const void *)(key));
    pthread_mutex_unlock(&_lock);
    return contains;
}

- (id)objectForKey:(id)key {
    if (!key) return nil;
    pthread_mutex_lock(&_lock);
    _SDLinkedMapNode *node = CFDictionaryGetValue(_lru->_dic, (__bridge const void *)(key));
    if (node) {
        time_t timestamp;
        time(&timestamp);
        
        node->_time = timestamp;
        [_lru bringNodeToHead:node];
    }
    pthread_mutex_unlock(&_lock);
    return node ? node->_value : nil;
}

- (void)setObject:(id)object forKey:(id)key {
    [self setObject:object forKey:key cost:0];
}

- (void)setObject:(id)object forKey:(id)key cost:(NSUInteger)cost {
    if (!key) return;
    if (!object) {
        [self removeObjectForKey:key];
        return;
    }
    pthread_mutex_lock(&_lock);
    _SDLinkedMapNode *node = CFDictionaryGetValue(_lru->_dic, (__bridge const void *)(key));
    
    time_t timestamp;
    time(&timestamp);
    NSTimeInterval now = timestamp;
    if (node) {
        _lru->_totalCost -= node->_cost;
        _lru->_totalCost += cost;
        node->_cost = cost;
        node->_time = now;
        node->_value = object;
        [_lru bringNodeToHead:node];
    } else {
        node = [_SDLinkedMapNode new];
        node->_cost = cost;
        node->_time = now;
        node->_key = key;
        node->_value = object;
        [_lru insertNodeAtHead:node];
    }
    if (_lru->_totalCost > _costLimit) {
        NSUInteger costLimit = _costLimit;
        
        dispatch_async(_queue, ^{
            [self trimToCost:costLimit];
        });
    }
    if (_lru->_totalCount > _countLimit) {
        _SDLinkedMapNode *tail = [_lru removeTailNode];
        
        dispatch_async(SDMemoryCacheGetReleaseQueue(), ^{
            [tail class]; // Hold and release in queue.
        });
    }
    pthread_mutex_unlock(&_lock);
}

- (void)removeObjectForKey:(id)key {
    if (!key) return;
    pthread_mutex_lock(&_lock);
    _SDLinkedMapNode *node = CFDictionaryGetValue(_lru->_dic, (__bridge const void *)(key));
    if (node) {
        [_lru removeNode:node];
        
        dispatch_async(SDMemoryCacheGetReleaseQueue(), ^{
            [node class]; // Hold and release in queue.
        });
    }
    pthread_mutex_unlock(&_lock);
}

- (void)removeAllObjects {
    pthread_mutex_lock(&_lock);
    [_lru removeAll];
    pthread_mutex_unlock(&_lock);
}

- (void)trimToCount:(NSUInteger)count {
    if (count == 0) {
        [self removeAllObjects];
        return;
    }
    [self _trimToCount:count];
}

- (void)trimToCost:(NSUInteger)cost {
    [self _trimToCost:cost];
}

- (void)trimToAge:(NSTimeInterval)age {
    [self _trimToAge:age];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p>", self.class, self];
}

@end
