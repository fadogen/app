import Foundation

enum PortValidator {

    static let validRange = 1024...65535

    static func validate(_ portString: String, fieldName: String? = nil) throws -> Int {
        guard let portNumber = Int(portString) else {
            throw PortValidationError.notANumber(fieldName: fieldName)
        }

        guard validRange.contains(portNumber) else {
            throw PortValidationError.outOfRange(fieldName: fieldName)
        }

        return portNumber
    }

    static func isValid(_ portString: String) -> Bool {
        guard let portNumber = Int(portString) else { return false }
        return validRange.contains(portNumber)
    }
}

// MARK: - Error Type

enum PortValidationError: LocalizedError {
    case notANumber(fieldName: String?)
    case outOfRange(fieldName: String?)

    var errorDescription: String? {
        switch self {
        case .notANumber(let fieldName):
            if let name = fieldName {
                return String(localized: "\(name) must be a number between 1024 and 65535")
            }
            return String(localized: "Port must be a number between 1024 and 65535")

        case .outOfRange(let fieldName):
            if let name = fieldName {
                return String(localized: "\(name) must be a number between 1024 and 65535")
            }
            return String(localized: "Port must be a number between 1024 and 65535")
        }
    }
}
