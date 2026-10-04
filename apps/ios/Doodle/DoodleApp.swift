import SwiftUI
import UserNotifications

@main
struct DoodleApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    #if DEBUG
    @AppStorage("prototypeMode") private var prototypeMode = false
    #endif

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if prototypeMode {
                ProtoRootView().tint(DoodleTheme.pink)
            } else {
                app
            }
            #else
            app
            #endif
        }
    }

    private var app: some View {
        RootView()
            .environmentObject(appState)
            .tint(DoodleTheme.pink)
    }
}

/// Receives the push token from iOS and shows notifications while the app is open.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        DoodleDevice.apnsToken = DoodleDevice.hex(deviceToken)
        Task { await DoodleDevice.register() }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    #if DEBUG
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        await MainActor.run {
            NotificationCenter.default.post(name: .doodleNotificationTapped, object: nil, userInfo: userInfo)
        }
    }
    #endif
}
