import Foundation
import Observation
import Security

@MainActor @Observable
final class ProfileStore {
    private(set) var profiles: [Pairing] = []
    var error: String?
    private let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.desklink.remote.profiles",
        kSecAttrAccount as String: "saved-macs"
    ]

    init() {
        var search = query
        search[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess, let data = result as? Data,
              let profiles = try? JSONDecoder().decode([Pairing].self, from: data) else {
            error = "Связка ключей iPhone недоступна (\(status))."
            return
        }
        self.profiles = profiles.filter(\.isValid)
    }

    @discardableResult
    func save(_ pairing: Pairing) -> Bool {
        guard pairing.isValid else { return false }
        var remaining = profiles.filter {
            $0.id != pairing.id && $0.fingerprint != pairing.fingerprint
        }
        remaining.insert(pairing, at: 0)
        return persist(remaining)
    }

    func remove(_ pairing: Pairing) {
        _ = persist(profiles.filter { $0.id != pairing.id })
    }

    private func persist(_ profiles: [Pairing]) -> Bool {
        do {
            let data = try JSONEncoder().encode(profiles)
            let values = [kSecValueData as String: data]
            var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
            if status == errSecItemNotFound {
                var item = query
                item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            }
            guard status == errSecSuccess else {
                throw DeskError.system("Не удалось сохранить Mac в связке ключей (\(status)).")
            }
            self.profiles = profiles
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}
