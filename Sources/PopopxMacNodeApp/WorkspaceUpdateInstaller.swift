//
//  WorkspaceUpdateInstaller.swift
//  PopopxMacNodeApp — the only code that turns a verified update package into a
//  running installer.
//
//  It is deliberately not a self-replacing updater. Replacing the running bundle
//  from inside the process would be a silent restart, which the brief forbids;
//  instead the package is opened with `NSWorkspace` so macOS (or the owner's
//  unzip) performs the install with its own prompts. The `UpdateCenter` calls this
//  only after a receipt-backed 「立即更新」, and only for a package whose size and
//  SHA-256 already matched the signed manifest.
//

import AppKit
import Foundation
import PopopxMacNode

struct WorkspaceUpdateInstaller: UpdateInstaller {
    func install(package: URL, release: UpdateRelease) async -> UpdateInstallOutcome {
        // Defence in depth: the centre staged this file, so anything outside the
        // staging directory means the path was rewritten after verification.
        let real = package.resolvingSymlinksInPath().standardizedFileURL
        let staging = AppPaths.updateStaging.resolvingSymlinksInPath().standardizedFileURL
        guard real.path.hasPrefix(staging.path + "/") else {
            return UpdateInstallOutcome(
                ok: false,
                message: "安装包不在暂存目录 / the package is outside the update staging directory"
            )
        }
        let format = release.package.format.lowercased()
        switch format {
        case "dmg", "pkg":
            let opened = await MainActor.run { NSWorkspace.shared.open(real) }
            guard opened else {
                return UpdateInstallOutcome(
                    ok: false,
                    message: "系统未接受安装包 / macOS refused to open the package"
                )
            }
            return UpdateInstallOutcome(
                ok: true,
                message: "已交给 macOS 安装器，请按系统提示完成 / handed to the macOS installer — finish in its prompt"
            )
        case "zip":
            await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([real]) }
            return UpdateInstallOutcome(
                ok: true,
                message: "安装包已在 Finder 中显示，由机主解压 / the verified archive is revealed for the owner"
            )
        default:
            return UpdateInstallOutcome(
                ok: false,
                message: "未知安装包格式 / unsupported package format: \(format)"
            )
        }
    }
}