import Foundation
import SwiftUI

class ListenBrainzManager: ObservableObject {
    // MARK: - Constants

    private enum LB {
        static let apiBaseURL = "https://api.listenbrainz.org/1/"
        static let minimumTrackDuration: Double = 30
        static let scrobbleThresholdRatio: Double = 0.5
        static let scrobbleThresholdSeconds: Double = 240
    }

    // MARK: - Properties

    @AppStorage("listenBrainzConnected")
    var isConnected: Bool = false

    var token: String?

    private var tokenValid: Bool = false

    private var isScrobblingEnabled: Bool {
        UserDefaults.standard.bool(forKey: "listenBrainzEnabled")
    }

    // MARK: - Initialization

    init() {
        if UserDefaults.standard.object(forKey: "listenBrainzEnabled") == nil {
            UserDefaults.standard.set(true, forKey: "listenBrainzEnabled")
        }

        if let savedToken = KeychainManager.retrieve(key: KeychainManager.Keys.listenbrainzToken) {
            self.token = savedToken
            self.tokenValid = true
        }
    }

    // MARK: - Public Methods

    func setToken(_ token: String) {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Logger.warning("ListenBrainz: Attempted to set empty token")
            return
        }

        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            let valid = await validateToken(trimmedToken)
            await MainActor.run {
                if valid {
                    self.token = trimmedToken
                    self.tokenValid = true
                    KeychainManager.save(key: KeychainManager.Keys.listenbrainzToken, value: trimmedToken)
                    self.isConnected = true
                    Logger.info("ListenBrainz: Token validated and saved")
                    NotificationManager.shared.addMessage(.info, "Connected to ListenBrainz")
                } else {
                    Logger.warning("ListenBrainz: Token validation failed")
                    NotificationManager.shared.addMessage(.error, "Invalid ListenBrainz token")
                }
            }
        }
    }

    func clearToken() {
        token = nil
        tokenValid = false
        KeychainManager.delete(key: KeychainManager.Keys.listenbrainzToken)
        isConnected = false
        Logger.info("ListenBrainz: Disconnected")
    }

    func trackStarted(_ track: Track, fullTrack: FullTrack? = nil) {
        guard isConnected, tokenValid, isScrobblingEnabled else { return }
        guard track.duration >= LB.minimumTrackDuration else {
            Logger.info("ListenBrainz: Track too short for now playing (\(track.duration)s)")
            return
        }

        Task {
            await sendNowPlaying(track, fullTrack: fullTrack)
        }
    }

    func trackFinished(_ track: Track, fullTrack: FullTrack? = nil) {
        guard isConnected, tokenValid, isScrobblingEnabled else { return }
        guard track.duration >= LB.minimumTrackDuration else {
            Logger.warning("ListenBrainz: Track too short to scrobble (\(track.duration)s)")
            return
        }

        Task {
            await scrobble(track, fullTrack: fullTrack)
        }
    }

    // MARK: - Token Validation

    private func validateToken(_ token: String) async -> Bool {
        guard let url = URL(string: "\(LB.apiBaseURL)validate-token") else {
            Logger.error("ListenBrainz: Failed to create validate URL")
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }

            if httpResponse.statusCode == 200,
               let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let valid = json["valid"] as? Bool {
                return valid
            }

            return false
        } catch {
            Logger.error("ListenBrainz: Token validation failed - \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - API Calls

    private func sendNowPlaying(_ track: Track, fullTrack: FullTrack?) async {
        guard let token = token else { return }

        let payload = buildPayload(track: track, fullTrack: fullTrack, includeTimestamp: false)
        let body: [String: Any] = [
            "listen_type": "playing_now",
            "payload": [payload]
        ]

        await submitListens(body: body, token: token)
    }

    private func scrobble(_ track: Track, fullTrack: FullTrack?) async {
        guard let token = token else { return }

        let listenedAt = Int(Date().timeIntervalSince1970)
        var payload = buildPayload(track: track, fullTrack: fullTrack, includeTimestamp: true)
        payload["listened_at"] = listenedAt

        let body: [String: Any] = [
            "listen_type": "single",
            "payload": [payload]
        ]

        await submitListens(body: body, token: token)
    }

    private func submitListens(body: [String: Any], token: String) async {
        guard let url = URL(string: "\(LB.apiBaseURL)submit-listens") else {
            Logger.error("ListenBrainz: Failed to create submit URL")
            return
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            Logger.error("ListenBrainz: Failed to serialize JSON")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                Logger.error("ListenBrainz: Invalid response")
                return
            }

            switch httpResponse.statusCode {
            case 200:
                Logger.info("ListenBrainz: Listen submitted successfully")
            case 400:
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorMsg = json["error"] as? String {
                    Logger.warning("ListenBrainz: Bad request - \(errorMsg)")
                }
            case 401:
                Logger.warning("ListenBrainz: Unauthorized - token may be invalid")
                await MainActor.run {
                    self.clearToken()
                }
            default:
                Logger.warning("ListenBrainz: Unexpected status \(httpResponse.statusCode)")
            }
        } catch {
            Logger.error("ListenBrainz: Submit failed - \(error.localizedDescription)")
        }
    }

    // MARK: - Payload Building

    private func buildPayload(track: Track, fullTrack: FullTrack?, includeTimestamp: Bool) -> [String: Any] {
        var trackMetadata: [String: Any] = [
            "artist_name": track.artist,
            "track_name": track.title
        ]

        if !track.album.isEmpty && track.album != "Unknown Album" {
            trackMetadata["release_name"] = track.album
        }

        var additionalInfo: [String: Any] = [:]

        if let full = fullTrack, let extended = full.extendedMetadata {
            if let recordingMbid = extended.musicBrainzTrackId {
                additionalInfo["recording_mbid"] = recordingMbid
            }
            if let releaseMbid = extended.musicBrainzAlbumId {
                additionalInfo["release_mbid"] = releaseMbid
            }
            if let releaseGroupMbid = extended.musicBrainzReleaseGroupId {
                additionalInfo["release_group_mbid"] = releaseGroupMbid
            }
            if let workId = extended.musicBrainzWorkId {
                additionalInfo["work_mbids"] = [workId]
            }
            if let artistMbid = extended.musicBrainzArtistId {
                additionalInfo["artist_mbids"] = [artistMbid]
            } else if let albumArtistMbid = extended.musicBrainzAlbumArtistId {
                additionalInfo["artist_mbids"] = [albumArtistMbid]
            }
        }

        if let trackNumber = fullTrack?.trackNumber {
            additionalInfo["tracknumber"] = trackNumber
        }

        let durationMs = Int(track.duration * 1000)
        if durationMs > 0 {
            additionalInfo["duration_ms"] = durationMs
        }

        additionalInfo["media_player"] = "Petrichor"
        additionalInfo["submission_client"] = "Petrichor"
        additionalInfo["submission_client_version"] = About.appVersion

        if !additionalInfo.isEmpty {
            trackMetadata["additional_info"] = additionalInfo
        }

        return ["track_metadata": trackMetadata]
    }
}
