import Cocoa

final class ForkUpdateChecker {
    struct Release {
        let version: String
        let pageURL: URL
    }

    enum Result {
        case updateAvailable(Release)
        case upToDate
    }

    static let shared = ForkUpdateChecker()
    var cachedResult: Result?

    private let manifestURL = URL(string: "https://raw.githubusercontent.com/Qiushi0919/alt-tab-macos/refs/heads/feature/multi-display-switcher/update.json")!
    private let lastCheckKey = "QiushiAltTabLastUpdateCheck"
    private let checkInterval: TimeInterval = 24 * 60 * 60
    private var timer: Timer?
    private var isChecking = false
    private var completions: [(Result) -> Void] = []
    private var presentAvailable = false
    private var presentUpToDate = false
    private var presentErrors = false

    func start() {
        if Preferences.updatePolicy == .autoInstall {
            Preferences.set("updatePolicy", UpdatePolicyPreference.autoCheck.indexAsString)
        }
        updateSchedule(for: Preferences.updatePolicy)
    }

    func updateSchedule(for policy: UpdatePolicyPreference) {
        timer?.invalidate()
        timer = nil
        guard policy != .manual else { return }
        let lastCheck = UserDefaults.standard.object(forKey: lastCheckKey) as? Date
        let delay = lastCheck.map { max(30, checkInterval - Date().timeIntervalSince($0)) } ?? 30
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.check(presentAvailable: true, presentUpToDate: false, presentErrors: false)
        }
    }

    func checkInteractively() {
        check(presentAvailable: true, presentUpToDate: true, presentErrors: true)
    }

    func checkForUpdateInformation(completion: @escaping (Result) -> Void) {
        check(presentAvailable: false, presentUpToDate: false, presentErrors: false, completion: completion)
    }

    func openRelease(_ release: Release) {
        NSWorkspace.shared.open(release.pageURL)
    }

    private func check(
        presentAvailable: Bool,
        presentUpToDate: Bool,
        presentErrors: Bool,
        completion: ((Result) -> Void)? = nil
    ) {
        if let completion { completions.append(completion) }
        self.presentAvailable = self.presentAvailable || presentAvailable
        self.presentUpToDate = self.presentUpToDate || presentUpToDate
        self.presentErrors = self.presentErrors || presentErrors
        guard !isChecking else { return }
        isChecking = true

        var request = URLRequest(url: manifestURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Qiushi-AltTab-Update-Checker", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.handle(data: data, response: response, error: error)
            }
        }.resume()
    }

    private func handle(data: Data?, response: URLResponse?, error: Error?) {
        guard error == nil,
              let data,
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            finish(result: .upToDate, errorMessage: NSLocalizedString("Unable to check for updates. Please try again later.", comment: ""))
            return
        }

        do {
            let latest = try JSONDecoder().decode(UpdateManifest.self, from: data)
            let result: Result
            if compareVersions(App.version, latest.version) == .orderedAscending {
                result = .updateAvailable(Release(version: normalizedVersion(latest.version), pageURL: latest.pageURL))
            } else {
                result = .upToDate
            }
            finish(result: result, errorMessage: nil)
        } catch {
            finish(result: .upToDate, errorMessage: NSLocalizedString("Unable to check for updates. Please try again later.", comment: ""))
        }
    }

    private func finish(result: Result, errorMessage: String?) {
        isChecking = false
        cachedResult = result
        if errorMessage == nil { UserDefaults.standard.set(Date(), forKey: lastCheckKey) }
        let callbacks = completions
        completions.removeAll()
        callbacks.forEach { $0(result) }

        if let errorMessage, presentErrors {
            showMessage(title: NSLocalizedString("Update check failed", comment: ""), body: errorMessage)
        } else {
            switch result {
            case let .updateAvailable(release) where presentAvailable:
                showAvailable(release)
            case .upToDate where presentUpToDate:
                showMessage(
                    title: NSLocalizedString("AltTab is up to date", comment: ""),
                    body: String(format: NSLocalizedString("You are running the latest custom build, v%@.", comment: ""), App.version)
                )
            default:
                break
            }
        }

        presentAvailable = false
        presentUpToDate = false
        presentErrors = false
        updateSchedule(for: Preferences.updatePolicy)
    }

    private func showAvailable(_ release: Release) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = NSLocalizedString("A new version of AltTab is available", comment: "")
        alert.informativeText = String(
            format: NSLocalizedString("You're running v%1$@. The custom build v%2$@ is available on GitHub.", comment: ""),
            App.version,
            release.version
        )
        alert.addButton(withTitle: NSLocalizedString("Open download page", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Later", comment: ""))
        if alert.runModal() == .alertFirstButtonReturn { openRelease(release) }
    }

    private func showMessage(title: String, body: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.runModal()
    }

    private func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        normalizedVersion(lhs).compare(normalizedVersion(rhs), options: .numeric)
    }

    private func normalizedVersion(_ value: String) -> String {
        value.lowercased().hasPrefix("v") ? String(value.dropFirst()) : value
    }
}

private struct UpdateManifest: Decodable {
    let version: String
    let pageURL: URL

    enum CodingKeys: String, CodingKey {
        case version
        case pageURL = "html_url"
    }
}
