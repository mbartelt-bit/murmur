import UIKit
import Capacitor

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
        // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration",
                                          sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

// Local bridge: only the native app can record; the browser preview cannot.
import Speech
import AVFoundation

@objc(MurmurViewController)
class MurmurViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(MurmurSpeechPlugin())
        bridge?.registerPluginInstance(MurmurStorePlugin())
    }
}

@objc(MurmurSpeechPlugin)
public class MurmurSpeechPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "MurmurSpeechPlugin"
    public let jsName = "MurmurSpeech"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "available", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "start", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cancel", returnType: CAPPluginReturnPromise)
    ]
    private var engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var sessionID: String?
    private var tapInstalled = false
    private var deadline: DispatchWorkItem?
    private var backgroundObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?

    public override func load() {
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.fail("Recording stopped when Murmur moved to the background. Your latest words are kept.")
        }
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            if let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, type == AVAudioSession.InterruptionType.began.rawValue {
                self?.fail("Recording was interrupted. Your latest words are kept; start again when you’re ready.")
            }
        }
    }
    deinit {
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        deadline?.cancel()
    }
    @objc func available(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let recognizer = SFSpeechRecognizer(locale: Locale(identifier: call.getString("locale") ?? "en-US"))
            let ready = recognizer?.supportsOnDeviceRecognition == true
            call.resolve(["available": ready, "reason": "On-device speech isn’t available for this language. Check downloaded dictation languages in iPhone Settings, or choose another language."])
        }
    }
    @objc func start(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard self.sessionID == nil else { call.reject("A recording is already active."); return }
            guard let id = call.getString("sessionId"), !id.isEmpty else { call.reject("Missing recording identifier."); return }
            self.sessionID = id
            SFSpeechRecognizer.requestAuthorization { authorization in
                DispatchQueue.main.async {
                    guard self.sessionID == id else { call.reject("Recording cancelled."); return }
                    guard authorization == .authorized else {
                        self.releaseResources()
                        call.reject("Allow Speech Recognition for Murmur in iPhone Settings to dictate."); return
                    }
                    AVAudioSession.sharedInstance().requestRecordPermission { granted in
                        DispatchQueue.main.async {
                            guard self.sessionID == id else { call.reject("Recording cancelled."); return }
                            guard granted else {
                                self.releaseResources()
                                call.reject("Allow Microphone access for Murmur in iPhone Settings to dictate."); return
                            }
                            self.begin(call, id: id)
                        }
                    }
                }
            }
        }
    }
    private func begin(_ call: CAPPluginCall, id: String) {
        let speech = SFSpeechRecognizer(locale: Locale(identifier: call.getString("locale") ?? "en-US"))
        guard let speech, speech.supportsOnDeviceRecognition, speech.isAvailable else {
            releaseResources()
            call.reject("On-device speech is unavailable for this language. No audio was sent to the cloud."); return
        }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audio.setActive(true, options: .notifyOthersOnDeactivation)
            engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                releaseResources(); call.reject("No working microphone was found."); return
            }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            request.contextualStrings = Array((call.getArray("hints", String.self) ?? []).prefix(80)).map { String($0.prefix(80)) }
            self.request = request
            self.recognizer = speech
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            tapInstalled = true
            task = speech.recognitionTask(with: request) { [weak self] result, error in
                DispatchQueue.main.async {
                    guard let self, self.sessionID == id else { return }
                    if let result {
                        self.notifyListeners("result", data: ["sessionId": id, "text": result.bestTranscription.formattedString, "final": result.isFinal])
                        if result.isFinal { self.releaseResources(); return }
                    }
                    if error != nil { self.fail("Speech recognition stopped before finishing. Your latest words are kept. Try again or check the installed speech language.") }
                }
            }
            engine.prepare()
            try engine.start()
            notifyListeners("state", data: ["sessionId": id, "state": "recording"])
            // Bound recordings to the speech service's supported short-dictation use.
            let timeout = DispatchWorkItem { [weak self] in if self?.sessionID == id { self?.finish() } }
            deadline = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 55, execute: timeout)
            call.resolve()
        } catch {
            releaseResources()
            call.reject("Could not open the microphone. Check permission and try again.")
        }
    }
    @objc func stop(_ call: CAPPluginCall) {
        DispatchQueue.main.async { self.finish(); call.resolve() }
    }
    private func finish() {
        guard let id = sessionID else { return }
        deadline?.cancel()
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio()
        notifyListeners("state", data: ["sessionId": id, "state": "finishing"])
        let timeout = DispatchWorkItem { [weak self] in
            if self?.sessionID == id { self?.fail("Recognition took too long to finish. Your latest words are kept in the draft.") }
        }
        deadline = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    }
    @objc func cancel(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let id = self.sessionID
            self.releaseResources()
            if let id { self.notifyListeners("state", data: ["sessionId": id, "state": "idle"]) }
            call.resolve()
        }
    }
    private func fail(_ message: String) {
        guard let id = sessionID else { return }
        releaseResources()
        notifyListeners("failure", data: ["sessionId": id, "message": message])
    }
    private func releaseResources() {
        sessionID = nil // Ignore callbacks from cancelled/previous sessions.
        deadline?.cancel(); deadline = nil
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio(); task?.cancel()
        task = nil; request = nil; recognizer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

@objc(MurmurStorePlugin)
public class MurmurStorePlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "MurmurStorePlugin"
    public let jsName = "MurmurStore"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "read", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "write", returnType: CAPPluginReturnPromise)
    ]
    private let io = DispatchQueue(label: "com.murmur.mobile.store")
    private func file() throws -> URL {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return directory.appendingPathComponent("murmur-v1.json")
    }
    @objc func read(_ call: CAPPluginCall) {
        io.async {
            do {
                let file = try self.file()
                guard FileManager.default.fileExists(atPath: file.path) else { call.resolve(["value": NSNull()]); return }
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 8_388_608 else { call.reject("Saved data is too large to open safely."); return }
                let data = try Data(contentsOf: file)
                guard let value = String(data: data, encoding: .utf8) else { call.reject("Saved data could not be decoded."); return }
                call.resolve(["value": value])
            } catch { call.reject("Could not read saved Murmur data. It has not been changed.") }
        }
    }
    @objc func write(_ call: CAPPluginCall) {
        guard let value = call.getString("value"), let data = value.data(using: .utf8), data.count <= 8_388_608 else {
            call.reject("Murmur data exceeds the storage limit."); return
        }
        io.async {
            do {
                try data.write(to: self.file(), options: [.atomic, .completeFileProtection])
                call.resolve()
            } catch { call.reject("Could not save Murmur data. The previous saved file is unchanged.") }
        }
    }
}
