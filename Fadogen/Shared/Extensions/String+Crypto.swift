import CryptoKit
import Foundation

extension String {

    func sha256Hash() -> String {
        let data = Data(utf8)
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
}
