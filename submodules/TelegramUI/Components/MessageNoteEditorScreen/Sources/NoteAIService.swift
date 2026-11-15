import Foundation
import TextFormat

/// What an AI search returns for an annotation.
public struct NoteAIResult: Equatable {
    /// At most `MessageNoteContent.maxTextLength` characters, in the language of the message.
    public var text: String
    /// A web image the service marks as safe to reuse.
    public var imageUrl: String?
    /// 1–3 source URLs.
    public var sources: [String]

    public init(text: String, imageUrl: String?, sources: [String]) {
        self.text = text
        self.imageUrl = imageUrl
        self.sources = sources
    }
}

public enum NoteAIError: Error {
    case nothingFound
    case failed
}

public protocol NoteAIRequest: AnyObject {
    func cancel()
}

/// Drafts an annotation for `anchor` by searching the web. `context` is the full message text, so that an
/// abbreviation resolves to the right meaning; `language` is the app's, a fallback for the message's.
/// The completion runs on the main queue, and never after `cancel()`.
public protocol NoteAIService {
    func generate(anchor: String, context: String, language: String, completion: @escaping (Swift.Result<NoteAIResult, NoteAIError>) -> Void) -> NoteAIRequest
}

/// A stand-in for a real backend (design demo): canned answers for a few words, and Wikipedia's public API (no key)
/// for any other word.
public final class NoteAIStubService: NoteAIService {
    private final class Request: NoteAIRequest {
        var isCancelled = false
        var task: URLSessionDataTask?

        func cancel() {
            self.isCancelled = true
            self.task?.cancel()
        }
    }

    private struct Entry {
        var keys: [String]
        var text: String
        var imageUrl: String?
        var sources: [String]
    }

    private static let entries: [Entry] = [
        Entry(
            keys: ["mpk"],
            text: "MPK Kraków (Miejskie Przedsiębiorstwo Komunikacyjne) runs the city's trams and buses: about 25 tram and 150 bus lines.",
            imageUrl: "https://thumb.wikimedia.org/wikipedia/commons/thumb/b/b7/StadlerTangoLajkonik%28HY857%29-UlicaBasztowa-POL%2C_Krak%C3%B3w.jpg/960px-StadlerTangoLajkonik%28HY857%29-UlicaBasztowa-POL%2C_Krak%C3%B3w.jpg",
            sources: ["https://www.mpk.krakow.pl", "https://en.wikipedia.org/wiki/MPK_Krak%C3%B3w"]
        ),
        Entry(
            keys: ["kazimierz", "kazimierzu"],
            text: "Kazimierz is Kraków's historic Jewish quarter: synagogues, Szeroka Street, Plac Nowy and the city's liveliest cafés and bars.",
            imageUrl: "https://thumb.wikimedia.org/wikipedia/commons/thumb/0/09/Szeroka_street%2C_view_to_S%2C_.Kazimierz%2C_Krak%C3%B3w%2C_Poland.jpg/960px-Szeroka_street%2C_view_to_S%2C_.Kazimierz%2C_Krak%C3%B3w%2C_Poland.jpg",
            sources: ["https://en.wikipedia.org/wiki/Kazimierz", "https://www.krakow.travel"]
        ),
        Entry(
            keys: ["wawel"],
            text: "Wawel is the royal castle and cathedral on a hill above the Vistula, the seat of Polish kings for five centuries.",
            imageUrl: "https://thumb.wikimedia.org/wikipedia/commons/thumb/6/6f/Krakow_-_Wawel_from_Vistula_-_4.jpg/960px-Krakow_-_Wawel_from_Vistula_-_4.jpg",
            sources: ["https://wawel.krakow.pl", "https://en.wikipedia.org/wiki/Wawel_Castle"]
        ),
        Entry(
            keys: ["kraków", "krakow", "krakowie"],
            text: "Kraków is Poland's second-largest city and its former capital, with a medieval Old Town and the Cloth Hall on the Main Square.",
            imageUrl: "https://thumb.wikimedia.org/wikipedia/commons/thumb/5/51/Krakow_-_Cloth_Hall_from_Basilica_-_1.jpg/960px-Krakow_-_Cloth_Hall_from_Basilica_-_1.jpg",
            sources: ["https://en.wikipedia.org/wiki/Krak%C3%B3w", "https://www.krakow.pl"]
        ),
        Entry(
            keys: ["vistula", "wisła", "wisla"],
            text: "The Vistula is Poland's longest river, 1,047 km. In Kraków it bends below Wawel Hill, with boulevards along both banks.",
            imageUrl: "https://thumb.wikimedia.org/wikipedia/commons/thumb/c/cf/Vistula_river_near_Wawel._Krakow%2C_Poland.jpg/960px-Vistula_river_near_Wawel._Krakow%2C_Poland.jpg",
            sources: ["https://en.wikipedia.org/wiki/Vistula"]
        ),
        Entry(
            keys: ["telegram"],
            text: "Telegram is a cloud-based messaging app with over a billion monthly users, known for channels, bots and Mini Apps.",
            imageUrl: nil,
            sources: ["https://telegram.org", "https://en.wikipedia.org/wiki/Telegram_(software)"]
        )
    ]

    public init() {
    }

    public func generate(anchor: String, context: String, language: String, completion: @escaping (Swift.Result<NoteAIResult, NoteAIError>) -> Void) -> NoteAIRequest {
        let request = Request()
        let key = anchor.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()

        // The language of the message wins over the app's: Cyrillic is Russian unless the app is
        // Ukrainian, so a note on a Russian message no longer comes back in Ukrainian.
        let wikipediaLanguage: String
        if context.unicodeScalars.contains(where: { (0x0400 ... 0x04FF).contains($0.value) }) {
            wikipediaLanguage = language.hasPrefix("uk") ? "uk" : "ru"
        } else if context.unicodeScalars.contains(where: { $0.properties.isAlphabetic }) {
            wikipediaLanguage = "en"
        } else if language.hasPrefix("uk") {
            wikipediaLanguage = "uk"
        } else if language.hasPrefix("ru") {
            wikipediaLanguage = "ru"
        } else {
            wikipediaLanguage = "en"
        }

        let finish: (Swift.Result<NoteAIResult, NoteAIError>) -> Void = { result in
            DispatchQueue.main.async {
                if !request.isCancelled {
                    completion(result)
                }
            }
        }

        if key == "error" {
            // Lets the demo show the failure state.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                finish(.failure(.failed))
            }
        } else if let entry = NoteAIStubService.entries.first(where: { $0.keys.contains(key) }) {
            let text = String(entry.text.prefix(MessageNoteContent.maxTextLength))
            let result = NoteAIResult(text: text, imageUrl: entry.imageUrl, sources: Array(entry.sources.prefix(3)))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                finish(.success(result))
            }
        } else if key.isEmpty {
            finish(.failure(.nothingFound))
        } else {
            NoteAIStubService.searchWikipedia(query: key, language: wikipediaLanguage, request: request, completion: finish)
        }
        return request
    }

    // MARK: - Wikipedia

    private static func fetchJson(_ url: URL, request: Request, completion: @escaping ([String: Any]?, Bool) -> Void) {
        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = 10.0
        let task = URLSession.shared.dataTask(with: urlRequest) { data, response, error in
            if error != nil {
                completion(nil, false)
                return
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            completion(json, statusCode == 200 || statusCode == 404)
        }
        request.task = task
        task.resume()
    }

    /// The best-matching article's summary: its first sentences, its thumbnail and its URL.
    private static func searchWikipedia(query: String, language: String, request: Request, completion: @escaping (Swift.Result<NoteAIResult, NoteAIError>) -> Void) {
        var components = URLComponents(string: "https://\(language).wikipedia.org/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: query),
            URLQueryItem(name: "srlimit", value: "1"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let searchUrl = components.url else {
            completion(.failure(.failed))
            return
        }
        fetchJson(searchUrl, request: request, completion: { json, isOk in
            guard isOk else {
                completion(.failure(.failed))
                return
            }
            guard let queryValue = json?["query"] as? [String: Any], let results = queryValue["search"] as? [[String: Any]], let title = results.first?["title"] as? String else {
                completion(.failure(.nothingFound))
                return
            }
            let encodedTitle = title.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? title
            guard let summaryUrl = URL(string: "https://\(language).wikipedia.org/api/rest_v1/page/summary/\(encodedTitle)") else {
                completion(.failure(.failed))
                return
            }
            fetchJson(summaryUrl, request: request, completion: { json, isOk in
                guard isOk else {
                    completion(.failure(.failed))
                    return
                }
                guard let json, (json["type"] as? String) != "disambiguation", let extract = json["extract"] as? String, !extract.isEmpty else {
                    completion(.failure(.nothingFound))
                    return
                }
                let imageUrl = (json["thumbnail"] as? [String: Any])?["source"] as? String
                let pageUrl = ((json["content_urls"] as? [String: Any])?["desktop"] as? [String: Any])?["page"] as? String
                let text = shortened(extract, maxLength: MessageNoteContent.maxTextLength)
                completion(.success(NoteAIResult(text: text, imageUrl: imageUrl, sources: pageUrl.flatMap { [$0] } ?? [])))
            })
        })
    }

    /// The text without stress marks, cut to whole sentences (or words) within `maxLength` characters.
    private static func shortened(_ text: String, maxLength: Int) -> String {
        var result = text.replacingOccurrences(of: "\u{0301}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if result.count <= maxLength {
            return result
        }
        let prefix = String(result.prefix(maxLength))
        if let sentenceEnd = prefix.range(of: ". ", options: .backwards), prefix.distance(from: prefix.startIndex, to: sentenceEnd.lowerBound) > maxLength / 3 {
            result = String(prefix[..<sentenceEnd.lowerBound]) + "."
        } else if let wordEnd = prefix.lastIndex(of: " ") {
            result = String(prefix[..<wordEnd]) + "…"
        } else {
            result = String(prefix.prefix(maxLength - 1)) + "…"
        }
        return result
    }
}
