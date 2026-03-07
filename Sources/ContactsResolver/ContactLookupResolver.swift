import Contacts
import Dispatch
import Foundation

public struct ResolvedContact: Sendable, Equatable {
  public let name: String
  public let label: String

  public init(name: String, label: String) {
    self.name = name
    self.label = label
  }
}

public enum ContactLookupResolver {
  public static func make() -> @Sendable (String) -> ResolvedContact? {
    let store = CNContactStore()

    guard hasContactsAccess(store: store) else {
      return { _ in nil }
    }

    do {
      let directory = try ContactDirectory(store: store)
      return { identifier in
        directory.resolve(identifier: identifier)
      }
    } catch {
      return { _ in nil }
    }
  }
}

private func hasContactsAccess(store: CNContactStore) -> Bool {
  switch CNContactStore.authorizationStatus(for: .contacts) {
  case .authorized:
    return true
  case .notDetermined:
    let semaphore = DispatchSemaphore(value: 0)
    let decision = AccessDecision()

    store.requestAccess(for: .contacts) { accessGranted, _ in
      decision.granted = accessGranted
      semaphore.signal()
    }

    semaphore.wait()
    return decision.granted
  case .denied, .restricted:
    return false
  @unknown default:
    return false
  }
}

private final class AccessDecision: @unchecked Sendable {
  var granted = false
}

private struct ContactDirectory: Sendable {
  let phoneMatches: [String: ResolvedContact]
  let emailMatches: [String: ResolvedContact]

  init(store: CNContactStore) throws {
    var phoneMatches: [String: ResolvedContact] = [:]
    var emailMatches: [String: ResolvedContact] = [:]

    let request = CNContactFetchRequest(keysToFetch: [
      CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
      CNContactOrganizationNameKey as CNKeyDescriptor,
      CNContactPhoneNumbersKey as CNKeyDescriptor,
      CNContactEmailAddressesKey as CNKeyDescriptor,
    ])

    try store.enumerateContacts(with: request) { contact, _ in
      let name = preferredName(for: contact)
      guard !name.isEmpty else {
        return
      }

      for phoneNumber in contact.phoneNumbers {
        let rawIdentifier = phoneNumber.value.stringValue.trimmingCharacters(
          in: .whitespacesAndNewlines
        )
        guard let normalized = normalizedPhone(rawIdentifier) else {
          continue
        }

        phoneMatches[normalized] = ResolvedContact(
          name: name,
          label: "\(name) (\(rawIdentifier))"
        )
      }

      for emailAddress in contact.emailAddresses {
        let rawIdentifier = String(emailAddress.value).trimmingCharacters(
          in: .whitespacesAndNewlines
        )
        let normalized = normalizedEmail(rawIdentifier)
        guard !normalized.isEmpty else {
          continue
        }

        emailMatches[normalized] = ResolvedContact(
          name: name,
          label: "\(name) (\(rawIdentifier))"
        )
      }
    }

    self.phoneMatches = phoneMatches
    self.emailMatches = emailMatches
  }

  func resolve(identifier: String) -> ResolvedContact? {
    if let normalizedPhone = normalizedPhone(identifier) {
      return phoneMatches[normalizedPhone]
    }

    let normalizedEmail = normalizedEmail(identifier)
    if !normalizedEmail.isEmpty {
      return emailMatches[normalizedEmail]
    }

    return nil
  }
}

private func preferredName(for contact: CNContact) -> String {
  let formattedName =
    CNContactFormatter.string(from: contact, style: .fullName)?
    .trimmingCharacters(in: .whitespacesAndNewlines)

  if let formattedName, !formattedName.isEmpty {
    return formattedName
  }

  let organizationName = contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
  return organizationName
}

private func normalizedPhone(_ identifier: String) -> String? {
  let digits = identifier.unicodeScalars
    .filter { CharacterSet.decimalDigits.contains($0) }
  let normalized = String(String.UnicodeScalarView(digits))

  guard !normalized.isEmpty else {
    return nil
  }

  if normalized.count == 11, normalized.hasPrefix("1") {
    return String(normalized.dropFirst())
  }

  return normalized
}

private func normalizedEmail(_ identifier: String) -> String {
  identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}
