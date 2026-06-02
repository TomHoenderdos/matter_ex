import Foundation
import Matter
import Security

final class MemoryStorage: NSObject, MTRStorage {
    private var values: [String: Data] = [:]
    private let lock = NSLock()

    func storageData(forKey key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func setStorageData(_ value: Data, forKey key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
        return true
    }

    func removeStorageData(forKey key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return values.removeValue(forKey: key) != nil
    }
}

final class P256Keypair: NSObject, MTRKeypair {
    private let privateKey: SecKey
    private let publicKeyRef: SecKey

    override init() {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey) else {
            let detail = error?.takeRetainedValue().localizedDescription ?? "unknown error"
            fatalError("Failed to create P-256 keypair: \(detail)")
        }

        self.privateKey = privateKey
        self.publicKeyRef = publicKey
    }

    func copyPublicKey() -> SecKey {
        publicKeyRef
    }

    func signMessageECDSA_DER(_ message: Data) -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            message as CFData,
            &error
        ) else {
            let detail = error?.takeRetainedValue().localizedDescription ?? "unknown error"
            fatalError("Failed to sign Matter message: \(detail)")
        }

        return signature as Data
    }
}

final class ProbeDelegate: NSObject, MTRDeviceControllerDelegate, MTRDeviceAttestationDelegate {
    private let nodeID: NSNumber
    private let commissioningParams: MTRCommissioningParameters
    private let done: DispatchSemaphore

    init(nodeID: NSNumber, commissioningParams: MTRCommissioningParameters, done: DispatchSemaphore) {
        self.nodeID = nodeID
        self.commissioningParams = commissioningParams
        self.done = done
    }

    func controller(_ controller: MTRDeviceController, statusUpdate status: MTRCommissioningStatus) {
        print("statusUpdate=\(status.rawValue)")
    }

    func controller(_ controller: MTRDeviceController, commissioningSessionEstablishmentDone error: Error?) {
        if let error {
            print("commissioningSessionEstablishmentDone error=\(error)")
            done.signal()
            return
        }

        print("commissioningSessionEstablishmentDone ok")
        do {
            try controller.commissionNode(withID: nodeID, commissioningParams: commissioningParams)
            print("commissionNode started")
        } catch {
            print("commissionNode failed error=\(error)")
            done.signal()
        }
    }

    func controller(_ controller: MTRDeviceController, commissioningComplete error: Error?, nodeID: NSNumber?) {
        if let error {
            print("commissioningComplete error=\(error)")
        } else {
            print("commissioningComplete ok nodeID=\(String(describing: nodeID))")
        }
        done.signal()
    }

    func deviceAttestationCompleted(for controller: MTRDeviceController,
                                    opaqueDeviceHandle: UnsafeMutableRawPointer,
                                    attestationDeviceInfo: MTRDeviceAttestationDeviceInfo,
                                    error: Error?) {
        print("attestationCompleted error=\(String(describing: error))")
        do {
            try controller.continueCommissioningDevice(opaqueDeviceHandle, ignoreAttestationFailure: true)
        } catch {
            print("continueCommissioningDevice failed error=\(error)")
            done.signal()
        }
    }
}

struct Options {
    var payload = "MT:Y.K9042C00KA0648G00"
    var ssid = "Tom&Ilona"
    var password: String?
    var nodeID: UInt64 = 124
    var timeoutSeconds = 180
}

func parseOptions() -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())

    while !args.isEmpty {
        let flag = args.removeFirst()
        guard !args.isEmpty else { fatalError("Missing value for \(flag)") }
        let value = args.removeFirst()

        switch flag {
        case "--payload":
            options.payload = value
        case "--ssid":
            options.ssid = value
        case "--password":
            options.password = value
        case "--node-id":
            options.nodeID = UInt64(value) ?? options.nodeID
        case "--timeout":
            options.timeoutSeconds = Int(value) ?? options.timeoutSeconds
        default:
            fatalError("Unknown option: \(flag)")
        }
    }

    return options
}

func readPassword(prompt: String) -> String {
    if let password = ProcessInfo.processInfo.environment["MATTER_WIFI_PASSWORD"], !password.isEmpty {
        return password
    }

    print(prompt, terminator: "")
    fflush(stdout)
    guard let password = readLine(strippingNewline: true) else {
        print("No password provided. Run from Terminal and enter it at the prompt, pass --password, or set MATTER_WIFI_PASSWORD.")
        exit(2)
    }
    return password
}

let options = parseOptions()
let password = options.password ?? readPassword(prompt: "Wi-Fi password: ")

guard let payload = MTRSetupPayload(payload: options.payload) else {
    fatalError("Invalid Matter onboarding payload")
}

let storage: MTRStorage
if let storageClass = NSClassFromString("MTRDeviceControllerLocalTestStorage") as? NSObject.Type,
   let localStorage = storageClass.init() as? MTRStorage {
    print("using MTRDeviceControllerLocalTestStorage")
    storage = localStorage
} else {
    print("using MemoryStorage")
    storage = MemoryStorage()
}
let factoryParams = MTRDeviceControllerFactoryParams(storage: storage)
let factory = MTRDeviceControllerFactory.sharedInstance()
do {
    try factory.start(factoryParams)
} catch {
    fatalError("Failed to start controller factory: \(error)")
}

let ipk = Data(repeating: 0x11, count: 16)
let rootKeypair = P256Keypair()
let startupParams = MTRDeviceControllerStartupParams(ipk: ipk, fabricID: 1, nocSigner: rootKeypair)
startupParams.vendorID = 0xFFF1
startupParams.nodeID = 1

let controller: MTRDeviceController
do {
    controller = try factory.createController(onNewFabric: startupParams)
} catch {
    fatalError("Failed to create controller: \(error)")
}

let nodeID = NSNumber(value: options.nodeID)
let params = MTRCommissioningParameters()
params.wifiSSID = options.ssid.data(using: .utf8)
params.wifiCredentials = password.data(using: .utf8)
params.deviceAttestationDelegate = nil
params.failSafeTimeout = 60
params.countryCode = "NL"

let done = DispatchSemaphore(value: 0)
let delegate = ProbeDelegate(nodeID: nodeID, commissioningParams: params, done: done)
params.deviceAttestationDelegate = delegate
let callbackQueue = DispatchQueue(label: "dev.matterex.apple-matter-probe.callbacks")
controller.setDeviceControllerDelegate(delegate, queue: callbackQueue)

do {
    try controller.setupCommissioningSession(with: payload, newNodeID: nodeID)
} catch {
    fatalError("Failed to start commissioning session: \(error)")
}

print("setupCommissioningSession started nodeID=\(nodeID)")
let deadline = DispatchTime.now() + .seconds(options.timeoutSeconds)
if done.wait(timeout: deadline) == .timedOut {
    print("timeout after \(options.timeoutSeconds)s")
}

controller.shutdown()
factory.stop()
