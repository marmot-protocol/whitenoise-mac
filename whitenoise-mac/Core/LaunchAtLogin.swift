//
//  LaunchAtLogin.swift
//  whitenoise-mac
//
//  Native login-item integration and its testable settings model.
//

import Observation
import ServiceManagement

enum LaunchAtLoginStatus: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

@MainActor
protocol LaunchAtLoginServicing: AnyObject {
    var status: LaunchAtLoginStatus { get }

    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
final class SystemLaunchAtLoginService: LaunchAtLoginServicing {
    private let service = SMAppService.mainApp

    var status: LaunchAtLoginStatus {
        switch service.status {
        case .notRegistered:
            .notRegistered
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .notFound
        @unknown default:
            .notFound
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
@Observable
final class LaunchAtLoginController {
    @ObservationIgnored private let service: any LaunchAtLoginServicing

    private(set) var status: LaunchAtLoginStatus
    private(set) var errorMessage: String?

    init(service: (any LaunchAtLoginServicing)? = nil) {
        let service = service ?? SystemLaunchAtLoginService()
        self.service = service
        self.status = service.status
    }

    var isEnabled: Bool {
        status == .enabled
    }

    func refresh() {
        errorMessage = nil
        status = service.status
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil

        do {
            if enabled {
                guard status != .enabled else { return }
                if status == .requiresApproval {
                    service.openSystemSettings()
                    return
                }
                try service.register()
            } else {
                guard status != .notRegistered else { return }
                try service.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        status = service.status
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }
}
