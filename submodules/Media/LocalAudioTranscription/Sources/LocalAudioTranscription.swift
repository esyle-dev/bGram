import Foundation
import SwiftSignalKit
import Speech

private var sharedRecognizers: [String: NSObject] = [:]

/// A recognised word with its position in the audio, in seconds.
public struct LocallyTimedWord {
    public var text: String
    public var start: Double
    public var end: Double
    
    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

private struct TranscriptionResult {
    var text: String
    var confidence: Float
    var isFinal: Bool
    var words: [LocallyTimedWord]
}

private func transcribeAudio(path: String, locale: String) -> Signal<TranscriptionResult?, NoError> {
    return Signal { subscriber in
        let disposable = MetaDisposable()
        
        if #available(iOS 13.0, *) {
            SFSpeechRecognizer.requestAuthorization { status in
                Queue.mainQueue().async {
                    switch status {
                    case .notDetermined:
                        subscriber.putNext(nil)
                        subscriber.putCompletion()
                    case .restricted:
                        subscriber.putNext(nil)
                        subscriber.putCompletion()
                    case .denied:
                        subscriber.putNext(nil)
                        subscriber.putCompletion()
                    case .authorized:
                        let speechRecognizer: SFSpeechRecognizer
                        if let sharedRecognizer = sharedRecognizers[locale] as? SFSpeechRecognizer {
                            speechRecognizer = sharedRecognizer
                        } else {
                            guard let speechRecognizerValue = SFSpeechRecognizer(locale: Locale(identifier: locale)), speechRecognizerValue.isAvailable else {
                                subscriber.putNext(nil)
                                subscriber.putCompletion()
                                
                                return
                            }
                            speechRecognizerValue.defaultTaskHint = .dictation
                            sharedRecognizers[locale] = speechRecognizerValue
                            speechRecognizer = speechRecognizerValue
                            
                            if locale == "en-US" {
                                speechRecognizer.supportsOnDeviceRecognition = true
                            } else {
                                speechRecognizer.supportsOnDeviceRecognition = false
                            }
                            speechRecognizer.supportsOnDeviceRecognition = true
                        }
                        
                        let tempFilePath = NSTemporaryDirectory() + "/\(UInt64.random(in: 0 ... UInt64.max)).m4a"
                        let _ = try? FileManager.default.copyItem(atPath: path, toPath: tempFilePath)
                        
                        let request = SFSpeechURLRecognitionRequest(url: URL(fileURLWithPath: tempFilePath))
                        if #available(iOS 16.0, *) {
                            request.addsPunctuation = true
                        }
                        request.requiresOnDeviceRecognition = speechRecognizer.supportsOnDeviceRecognition
                        request.shouldReportPartialResults = false
                        
                        let task = speechRecognizer.recognitionTask(with: request, resultHandler: { result, error in
                            if let result = result {
                                var confidence: Float = 0.0
                                for segment in result.bestTranscription.segments {
                                    confidence += segment.confidence
                                }
                                confidence /= Float(result.bestTranscription.segments.count)
                                let words = result.bestTranscription.segments.map { segment -> LocallyTimedWord in
                                    return LocallyTimedWord(text: segment.substring, start: segment.timestamp, end: segment.timestamp + segment.duration)
                                }
                                subscriber.putNext(TranscriptionResult(text: result.bestTranscription.formattedString, confidence: confidence, isFinal: result.isFinal, words: words))
                                
                                if result.isFinal {
                                    subscriber.putCompletion()
                                }
                            } else {
                                print("transcribeAudio: locale: \(locale), error: \(String(describing: error))")
                                
                                subscriber.putNext(nil)
                                subscriber.putCompletion()
                            }
                        })
                        
                        disposable.set(ActionDisposable {
                            task.cancel()
                        })
                    @unknown default:
                        subscriber.putNext(nil)
                        subscriber.putCompletion()
                    }
                }
            }
        } else {
            subscriber.putNext(nil)
            subscriber.putCompletion()
        }
        
        return disposable
    }
    |> runOn(.mainQueue())
}

public struct LocallyTranscribedAudio {
    public var text: String
    public var isFinal: Bool
}

/// Recognises the audio in each locale and keeps the most confident result.
private func bestTranscription(path: String, locales: [String]) -> Signal<TranscriptionResult?, NoError> {
    var signals: [Signal<TranscriptionResult?, NoError>] = []
    for locale in locales {
        signals.append(transcribeAudio(path: path, locale: locale))
    }
    var resultSignal: Signal<[TranscriptionResult?], NoError> = .single([])
    for signal in signals {
        resultSignal = resultSignal |> mapToSignal { result -> Signal<[TranscriptionResult?], NoError> in
            return signal |> map { next in
                return result + [next]
            }
        }
    }
    
    return resultSignal
    |> map { results -> TranscriptionResult? in
        let sortedResults = results.compactMap({ $0 }).sorted(by: { lhs, rhs in
            return lhs.confidence > rhs.confidence
        })
        return sortedResults.first
    }
}

public func transcribeAudio(path: String, appLocale: String) -> Signal<LocallyTranscribedAudio?, NoError> {
    var locales: [String] = []
    if !locales.contains(Locale.current.identifier) {
        locales.append(Locale.current.identifier)
    }
    if locales.isEmpty {
        locales.append("en-US")
    }
    
    return bestTranscription(path: path, locales: locales)
    |> map { result -> LocallyTranscribedAudio? in
        return result.flatMap { result -> LocallyTranscribedAudio in
            return LocallyTranscribedAudio(text: result.text, isFinal: result.isFinal)
        }
    }
}

/// The same recognition, but the result is the words with the time each one is spoken. Nil when recognition is
/// unavailable (no permission, unsupported language) or found no speech.
public func transcribeAudioWithTimings(path: String, locales: [String]) -> Signal<[LocallyTimedWord]?, NoError> {
    return bestTranscription(path: path, locales: locales)
    |> map { result -> [LocallyTimedWord]? in
        guard let result, !result.words.isEmpty else {
            return nil
        }
        return result.words
    }
}
