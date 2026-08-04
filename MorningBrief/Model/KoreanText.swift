import Foundation

/// This build is for Korean readers only, so nothing here follows the device
/// language. Every formatter and every generated sentence is pinned to Korean —
/// a phone set to English must still say "8월 4일 화요일".
extension Locale {
    static let brief = Locale(identifier: "ko_KR")
}

/// Whether a word ends in a 받침, which is what every Korean particle branches
/// on. `ㄹ` is called out separately because 으로/로 treats it as a vowel.
enum KoreanEnding {
    case vowel
    case rieul
    case consonant

    /// The words in front of these particles are calendar and reminder titles
    /// the reader typed, so the ending has to be resolved at runtime rather than
    /// written into the sentence. A title that ends in something unpronounceable
    /// — an emoji, a bracket, a Han character — falls back to `.vowel`, the form
    /// that reads least wrong when it is wrong.
    static func of(_ word: String) -> KoreanEnding {
        guard let character = word.reversed().first(where: { $0.isLetter || $0.isNumber }),
              let scalar = character.unicodeScalars.first
        else { return .vowel }

        // 가 ... 힣: the final consonant is the last of the 28 jamo slots.
        if (0xAC00...0xD7A3).contains(scalar.value) {
            switch (scalar.value - 0xAC00) % 28 {
            case 0: return .vowel
            case 8: return .rieul
            default: return .consonant
            }
        }

        // Read as 영 일 이 삼 사 오 육 칠 팔 구.
        if let digit = character.wholeNumberValue, (0...9).contains(digit) {
            switch digit {
            case 1, 7, 8: return .rieul
            case 0, 3, 6: return .consonant
            default: return .vowel
            }
        }

        // 엘, 알, 엠, 엔 — the Latin letters Korean reads with a 받침.
        if character.isASCII {
            switch character.lowercased() {
            case "l", "r": return .rieul
            case "m", "n": return .consonant
            default: return .vowel
            }
        }

        return .vowel
    }
}

/// The particles the brief needs, attached to whatever word precedes them.
enum Josa {
    case topic    // 은 / 는
    case subject  // 이 / 가
    case object   // 을 / 를
    case with     // 과 / 와
    case by       // 으로 / 로
    case copula   // 이에요 / 예요

    func attached(to word: String) -> String {
        word + form(after: KoreanEnding.of(word))
    }

    private func form(after ending: KoreanEnding) -> String {
        switch self {
        case .topic:   return ending == .vowel ? "는" : "은"
        case .subject: return ending == .vowel ? "가" : "이"
        case .object:  return ending == .vowel ? "를" : "을"
        case .with:    return ending == .vowel ? "와" : "과"
        // "서울로", not "서울으로".
        case .by:      return ending == .consonant ? "으로" : "로"
        case .copula:  return ending == .vowel ? "예요" : "이에요"
        }
    }
}

extension String {
    /// `"회의".josa(.object)` -> `"회의를"`
    func josa(_ josa: Josa) -> String {
        josa.attached(to: self)
    }
}

enum KoreanDuration {
    /// 45 -> "45분", 120 -> "2시간", 150 -> "2시간 30분"
    static func spelled(minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes)분" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)시간" : "\(hours)시간 \(remainder)분"
    }
}
