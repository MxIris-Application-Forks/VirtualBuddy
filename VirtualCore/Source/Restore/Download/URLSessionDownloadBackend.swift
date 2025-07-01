//
//  URLSessionDownloadBackend.swift
//  VirtualCore
//
//  Created by Guilherme Rambo on 07/06/22.
//

import Foundation
import Combine
import OSLog
import BuddyFoundation

public final class URLSessionDownloadBackend: NSObject, ObservableObject, DownloadBackend {

    private let logger = Logger(subsystem: VirtualCoreConstants.subsystemName, category: "URLSessionDownloadBackend")

    let library: VMLibraryController
    public var cookie: String?

    public init(library: VMLibraryController, cookie: String?) {
        self.library = library
        self.cookie = cookie
    }

    private var downloadTask: URLSessionDownloadTask?

    private var isInFailedState: Bool {
        guard case .failed = state else { return false }
        return true
    }

    public private(set) lazy var statePublisher: AnyPublisher<DownloadState, Never> = $state.eraseToAnyPublisher()

    @Published
    public private(set) var state = DownloadState.idle

    private lazy var session = makeSession()

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 16
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    private var destinationURL: URL?

    @MainActor
    public func startDownload(with url: URL) {
        logger.debug("Start download from \(url.absoluteString.quoted)")

        session = makeSession()

        resetProgress()

        state = .downloading(nil, nil)

        let filename = url.lastPathComponent

        self.destinationURL = VBSettings.current.downloadsDirectoryURL.appendingPathComponent(filename)

        var request = URLRequest(url: url)

        request.setValue(cookie, forHTTPHeaderField: "Cookie")

        downloadTask = session.downloadTask(with: request)
        downloadTask?.delegate = self
        downloadTask?.resume()
    }

    @MainActor
    public func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil

        session.finishTasksAndInvalidate()
    }

    private let minElapsedProgressForETA: Double = 0.01
    private var elapsedTime: Double = 0
    private var ppsObservations: [Double] = []
    private let ppsObservationsLimit = 500
    private var ppsAverage: Double {
        guard !ppsObservations.isEmpty else { return -1 }
        return ppsObservations.reduce(Double(0), +) / Double(ppsObservations.count)
    }

    private var pps: Double = -1

    private var eta: Double = -1

    private var lastProgressDate = Date()

    private var progress: Double = 0

    private func resetProgress() {
        elapsedTime = 0
        eta = -1
        pps = -1
        ppsObservations = []
    }

}

extension URLSessionDownloadBackend: URLSessionDownloadDelegate, URLSessionDelegate {

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        logger.debug("Will perform HTTP redirection \(response)")

        if request.url?.absoluteString.lowercased().contains("unauthorized") == true {
            DispatchQueue.main.async {
                self.state = .failed("The download failed due to missing authentication credentials.")
            }
            return nil
        } else {
            if let newCookie = response.value(forHTTPHeaderField: "Set-Cookie"), let firstItem = newCookie.components(separatedBy: ";").first {
                var newRequest = request
                let newCookieValue = (newRequest.value(forHTTPHeaderField: "Cookie") ?? "") + "; " + firstItem
                newRequest.setValue(newCookieValue, forHTTPHeaderField: "Cookie")
                return newRequest
            } else {
                return request
            }
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard !isInFailedState else { return }

        logger.notice("Download finished to \(location.path.quoted)")

        if let response = downloadTask.response as? HTTPURLResponse {
            guard 200..<300 ~= response.statusCode else {
                logger.error("Download failed with HTTP \(response.statusCode)")

                state = .failed("HTTP error \(response.statusCode). Please check the download link.")
                return
            }
        } else {
            logger.fault("Download task finished without a valid response!")
        }

        guard let destinationURL = destinationURL else {
            state = .failed("Missing destination URL.")
            assertionFailure("WAT")
            return
        }

        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }

            try FileManager.default.moveItem(at: location, to: destinationURL)

            DispatchQueue.main.async { self.state = .done(destinationURL) }
        } catch {
            DispatchQueue.main.async { self.state = .failed("Failed to move downloaded file: \(error.localizedDescription)") }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            logger.error("Download failed - \(error, privacy: .public)")
        } else {
            logger.notice("Download completed")
        }

        // Successful completion is handled in `urlSession:downloadTask:didFinishDownloadingTo`.
        guard let error = error else { return }
        state = .failed(error.localizedDescription)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        DispatchQueue.main.async { [self] in
            let interval = Date().timeIntervalSince(lastProgressDate)
            lastProgressDate = Date()

            let percent = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)

            updateProgress(with: percent, interval: interval)
        }
    }

    private func updateProgress(with progress: Double, interval: Double) {
        let currentPPS = progress / elapsedTime

        if currentPPS.isFinite && !currentPPS.isZero && !currentPPS.isNaN {
            ppsObservations.append(currentPPS)
            if ppsObservations.count >= ppsObservationsLimit {
                ppsObservations.removeFirst()
            }
        }

        elapsedTime += interval

        if self.progress > self.minElapsedProgressForETA {
            if pps < 0 {
                pps = progress / elapsedTime
            }

            eta = (1/ppsAverage) - elapsedTime

            self.state = .downloading(progress, eta)
        } else {
            self.state = .downloading(progress, nil)
        }

        self.progress = progress
    }

}
