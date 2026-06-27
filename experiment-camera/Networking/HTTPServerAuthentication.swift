//
//  HTTPServerAuthentication.swift
//  experiment-camera
//
//  Split from CameraCaptureNetworking.swift.
//

import Foundation

struct HTTPServerAuthentication {
    static let usernameStorageKey = "httpServerUsername"
    static let passwordStorageKey = "httpServerPassword"
    static let defaultUsername = "kamera"
    static let defaultPassword = "lozinka"

    let username: String
    let password: String
    let isEnabled: Bool

    static func currentCredentials(userDefaults: UserDefaults = .standard) -> HTTPServerAuthentication {
        let storedUsername = userDefaults.string(forKey: usernameStorageKey)
        let storedPassword = userDefaults.string(forKey: passwordStorageKey)

        if isBlank(storedUsername), isBlank(storedPassword) {
            return HTTPServerAuthentication(username: "", password: "", isEnabled: false)
        }

        return HTTPServerAuthentication(
            username: sanitizedCredential(
                storedUsername,
                defaultValue: defaultUsername
            ),
            password: sanitizedCredential(
                storedPassword,
                defaultValue: defaultPassword
            ),
            isEnabled: true
        )
    }

    nonisolated func authorizes(headerValue: String?) -> Bool {
        guard isEnabled else {
            return true
        }

        guard let headerValue else {
            return false
        }

        let parts = headerValue.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2,
              parts[0].lowercased() == "basic",
              let decodedData = Data(base64Encoded: String(parts[1])),
              let decodedValue = String(data: decodedData, encoding: .utf8),
              let separatorIndex = decodedValue.firstIndex(of: ":") else {
            return false
        }

        let providedUsername = String(decodedValue[..<separatorIndex])
        let providedPassword = String(decodedValue[decodedValue.index(after: separatorIndex)...])
        return secureCompare(providedUsername, username) && secureCompare(providedPassword, password)
    }

    private static func isBlank(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
    }

    private static func sanitizedCredential(_ value: String?, defaultValue: String) -> String {
        guard let value else {
            return defaultValue
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? defaultValue : trimmedValue
    }

    nonisolated private func secureCompare(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        var difference = lhsBytes.count ^ rhsBytes.count
        let maxCount = max(lhsBytes.count, rhsBytes.count)

        for index in 0..<maxCount {
            let lhsByte = index < lhsBytes.count ? lhsBytes[index] : 0
            let rhsByte = index < rhsBytes.count ? rhsBytes[index] : 0
            difference |= Int(lhsByte ^ rhsByte)
        }

        return difference == 0
    }
}
