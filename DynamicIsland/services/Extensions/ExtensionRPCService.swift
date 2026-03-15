/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation
import Defaults
import AtollExtensionKit

/// Handles JSON-RPC method calls for a single WebSocket connection.
/// Mirrors the functionality of `ExtensionXPCService` but uses JSON-RPC transport.
@MainActor
final class ExtensionRPCService {
    let bundleIdentifier: String
    private weak var server: ExtensionRPCServer?

    private let liveActivityManager = ExtensionLiveActivityManager.shared
    private let widgetManager = ExtensionLockScreenWidgetManager.shared
    private let notchManager = ExtensionNotchExperienceManager.shared
    private let authorizationManager = ExtensionAuthorizationManager.shared

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(bundleIdentifier: String, server: ExtensionRPCServer) {
        self.bundleIdentifier = bundleIdentifier
        self.server = server
    }

    // MARK: - Method Routing

    func handleRequest(_ request: RPCRequest) -> Data {
        let result: Codable

        switch request.method {
        case "atoll.getVersion":
            result = handleGetVersion(id: request.id)

        case "atoll.requestAuthorization":
            result = handleRequestAuthorization(params: request.params, id: request.id)

        case "atoll.checkAuthorization":
            result = handleCheckAuthorization(params: request.params, id: request.id)

        case "atoll.presentLiveActivity":
            result = handlePresentLiveActivity(params: request.params, id: request.id)

        case "atoll.updateLiveActivity":
            result = handleUpdateLiveActivity(params: request.params, id: request.id)

        case "atoll.dismissLiveActivity":
            result = handleDismissLiveActivity(params: request.params, id: request.id)

        case "atoll.presentLockScreenWidget":
            result = handlePresentLockScreenWidget(params: request.params, id: request.id)

        case "atoll.updateLockScreenWidget":
            result = handleUpdateLockScreenWidget(params: request.params, id: request.id)

        case "atoll.dismissLockScreenWidget":
            result = handleDismissLockScreenWidget(params: request.params, id: request.id)

        case "atoll.presentNotchExperience":
            result = handlePresentNotchExperience(params: request.params, id: request.id)

        case "atoll.updateNotchExperience":
            result = handleUpdateNotchExperience(params: request.params, id: request.id)

        case "atoll.dismissNotchExperience":
            result = handleDismissNotchExperience(params: request.params, id: request.id)

        default:
            result = RPCErrorResponse(
                error: RPCErrorObject(code: RPCErrorCode.methodNotFound, message: "Method not found: \(request.method)"),
                id: request.id
            )
        }

        return (try? encoder.encode(result)) ?? Data()
    }

    // MARK: - Version

    private func handleGetVersion(id: String) -> RPCSuccessResponse {
        RPCSuccessResponse(
            result: ["version": .string(AtollExtensionKitVersion)],
            id: id
        )
    }

    // MARK: - Authorization

    private func handleRequestAuthorization(params: RPCParams?, id: String) -> Codable {
        guard Defaults[.enableThirdPartyExtensions] else {
            return RPCErrorResponse(
                error: RPCErrorObject(code: RPCErrorCode.featureDisabled, message: "Extensions are disabled"),
                id: id
            )
        }

        let bi = params?["bundleIdentifier"]?.stringValue ?? bundleIdentifier
        let entry = authorizationManager.ensureEntryExists(bundleIdentifier: bi, appName: bi)

        if entry.isAuthorized {
            return RPCSuccessResponse(result: ["authorized": .bool(true)], id: id)
        }

        // Auto-authorize for now (user can revoke in settings)
        authorizationManager.authorize(bundleIdentifier: bi, appName: bi)
        logDiagnostics("Authorized RPC client \(bi)")

        return RPCSuccessResponse(result: ["authorized": .bool(true)], id: id)
    }

    private func handleCheckAuthorization(params: RPCParams?, id: String) -> Codable {
        let bi = params?["bundleIdentifier"]?.stringValue ?? bundleIdentifier

        guard Defaults[.enableThirdPartyExtensions] else {
            return RPCSuccessResponse(result: ["authorized": .bool(false)], id: id)
        }

        let entry = authorizationManager.authorizationEntry(for: bi)
        let authorized = entry?.isAuthorized ?? false

        return RPCSuccessResponse(result: ["authorized": .bool(authorized)], id: id)
    }

    // MARK: - Live Activities

    private func handlePresentLiveActivity(params: RPCParams?, id: String) -> Codable {
        guard let descriptorData = params?.jsonData(for: "descriptor") else {
            return errorResponse(code: RPCErrorCode.invalidParams, message: "Missing descriptor", id: id)
        }

        do {
            let descriptor = try decoder.decode(AtollLiveActivityDescriptor.self, from: descriptorData)
            try ExtensionDescriptorValidator.validate(descriptor)
            try liveActivityManager.present(descriptor: descriptor, bundleIdentifier: descriptor.bundleIdentifier)
            logDiagnostics("RPC: Presented live activity \(descriptor.id) for \(descriptor.bundleIdentifier)")
            return RPCSuccessResponse(result: ["success": .bool(true)], id: id)
        } catch let error as ExtensionValidationError {
            return errorResponse(from: error, id: id)
        } catch {
            return errorResponse(code: RPCErrorCode.internalError, message: error.localizedDescription, id: id)
        }
    }

    private func handleUpdateLiveActivity(params: RPCParams?, id: String) -> Codable {
        guard let descriptorData = params?.jsonData(for: "descriptor") else {
            return errorResponse(code: RPCErrorCode.invalidParams, message: "Missing descriptor", id: id)
        }

        do {
            let descriptor = try decoder.decode(AtollLiveActivityDescriptor.self, from: descriptorData)
            try liveActivityManager.update(descriptor: descriptor, bundleIdentifier: descriptor.bundleIdentifier)
            logDiagnostics("RPC: Updated live activity \(descriptor.id) for \(descriptor.bundleIdentifier)")
            return RPCSuccessResponse(result: ["success": .bool(true)], id: id)
        } catch let error as ExtensionValidationError {
            return errorResponse(from: error, id: id)
        } catch {
            return errorResponse(code: RPCErrorCode.internalError, message: error.localizedDescription, id: id)
        }
    }

    private func handleDismissLiveActivity(params: RPCParams?, id: String) -> Codable {
        guard let activityID = params?["activityID"]?.stringValue else {
            return errorResponse(code: RPCErrorCode.invalidParams, message: "Missing activityID", id: id)
        }
        let bi = params?["bundleIdentifier"]?.stringValue ?? bundleIdentifier
        liveActivityManager.dismiss(activityID: activityID, bundleIdentifier: bi)
        logDiagnostics("RPC: Dismissed live activity \(activityID) for \(bi)")
        return RPCSuccessResponse(result: ["success": .bool(true)], id: id)
    }

    // MARK: - Lock Screen Widgets

    private func handlePresentLockScreenWidget(params: RPCParams?, id: String) -> Codable {
        guard let descriptorData = params?.jsonData(for: "descriptor") else {
            return errorResponse(code: RPCErrorCode.invalidParams, message: "Missing descriptor", id: id)
        }

        do {
            let descriptor = try decoder.decode(AtollLockScreenWidgetDescriptor.self, from: descriptorData)
            try ExtensionDescriptorValidator.validate(descriptor)
            try widgetManager.present(descriptor: descriptor, bundleIdentifier: descriptor.bundleIdentifier)
            logDiagnostics("RPC: Presented widget \(descriptor.id) for \(descriptor.bundleIdentifier)")
            return RPCSuccessResponse(result: ["success": .bool(true)], id: id)
        } catch let error as ExtensionValidationError {
            return errorResponse(from: error, id: id)
        } catch {
            return errorResponse(code: RPCErrorCode.internalError, message: error.localizedDescription, id: id)
        }
    }

    private func handleUpdateLockScreenWidget(params: RPCParams?, id: String) -> Codable {
        guard let descriptorData = params?.jsonData(for: "descriptor") else {
            return errorResponse(code: RPCErrorCode.invalidParams, message: "Missing descriptor", id: id)
        }

        do {
            let descriptor = try decoder.decode(AtollLockScreenWidgetDescriptor.self, from: descriptorData)
            try widgetManager.update(descriptor: descriptor, bundleIdentifier: descriptor.bundleIdentifier)
            logDiagnostics("RPC: Updated widget \(descriptor.id) for \(descriptor.bundleIdentifier)")
            return RPCSuccessResponse(result: ["success": .bool(true)], id: id)
        } catch let error as ExtensionValidationError {
            return errorResponse(from: error, id: id)
        } catch {
            return errorResponse(code: RPCErrorCode.internalError, message: error.localizedDescription, id: id)
        }
    }

    private func handleDismissLockScreenWidget(params: RPCParams?, id: String) -> Codable {
        guard let widgetID = params?["widgetID"]?.stringValue else {
            return errorResponse(code: RPCErrorCode.invalidParams, message: "Missing widgetID", id: id)
        }
        let bi = params?["bundleIdentifier"]?.stringValue ?? bundleIdentifier
        widgetManager.dismiss(widgetID: widgetID, bundleIdentifier: bi)
        logDiagnostics("RPC: Dismissed widget \(widgetID) for \(bi)")
        return RPCSuccessResponse(result: ["success": .bool(true)], id: id)
    }

    // MARK: - Notch Experiences

    private func handlePresentNotchExperience(params: RPCParams?, id: String) -> Codable {
        guard let descriptorData = params?.jsonData(for: "descriptor") else {
            return errorResponse(code: RPCErrorCode.invalidParams, message: "Missing descriptor", id: id)
        }

        do {
            let descriptor = try decoder.decode(AtollNotchExperienceDescriptor.self, from: descriptorData)
            try ExtensionDescriptorValidator.validate(descriptor)
            try notchManager.present(descriptor: descriptor, bundleIdentifier: descriptor.bundleIdentifier)
            logDiagnostics("RPC: Presented notch experience \(descriptor.id) for \(descriptor.bundleIdentifier)")
            return RPCSuccessResponse(result: ["success": .bool(true)], id: id)
        } catch let error as ExtensionValidationError {
            return errorResponse(from: error, id: id)
        } catch {
            return errorResponse(code: RPCErrorCode.internalError, message: error.localizedDescription, id: id)
        }
    }

    private func handleUpdateNotchExperience(params: RPCParams?, id: String) -> Codable {
        guard let descriptorData = params?.jsonData(for: "descriptor") else {
            return errorResponse(code: RPCErrorCode.invalidParams, message: "Missing descriptor", id: id)
        }

        do {
            let descriptor = try decoder.decode(AtollNotchExperienceDescriptor.self, from: descriptorData)
            try notchManager.update(descriptor: descriptor, bundleIdentifier: descriptor.bundleIdentifier)
            logDiagnostics("RPC: Updated notch experience \(descriptor.id) for \(descriptor.bundleIdentifier)")
            return RPCSuccessResponse(result: ["success": .bool(true)], id: id)
        } catch let error as ExtensionValidationError {
            return errorResponse(from: error, id: id)
        } catch {
            return errorResponse(code: RPCErrorCode.internalError, message: error.localizedDescription, id: id)
        }
    }

    private func handleDismissNotchExperience(params: RPCParams?, id: String) -> Codable {
        guard let experienceID = params?["experienceID"]?.stringValue else {
            return errorResponse(code: RPCErrorCode.invalidParams, message: "Missing experienceID", id: id)
        }
        let bi = params?["bundleIdentifier"]?.stringValue ?? bundleIdentifier
        notchManager.dismiss(experienceID: experienceID, bundleIdentifier: bi)
        logDiagnostics("RPC: Dismissed notch experience \(experienceID) for \(bi)")
        return RPCSuccessResponse(result: ["success": .bool(true)], id: id)
    }

    // MARK: - Helpers

    private func errorResponse(code: Int, message: String, id: String) -> RPCErrorResponse {
        RPCErrorResponse(
            error: RPCErrorObject(code: code, message: message),
            id: id
        )
    }

    private func errorResponse(from error: ExtensionValidationError, id: String) -> RPCErrorResponse {
        let code: Int
        switch error {
        case .featureDisabled:     code = RPCErrorCode.featureDisabled
        case .unauthorized:        code = RPCErrorCode.unauthorized
        case .invalidDescriptor:   code = RPCErrorCode.descriptorInvalid
        case .exceedsCapacity:     code = RPCErrorCode.capacityExceeded
        case .unsupportedContent:  code = RPCErrorCode.unsupported
        case .rateLimited:         code = RPCErrorCode.internalError
        case .duplicateIdentifier: code = RPCErrorCode.descriptorInvalid
        }
        return RPCErrorResponse(
            error: RPCErrorObject(code: code, message: error.localizedDescription ?? "Unknown error"),
            id: id
        )
    }

    private func logDiagnostics(_ message: String) {
        guard Defaults[.extensionDiagnosticsLoggingEnabled] else { return }
        Logger.log(message, category: .extensions)
    }
}
