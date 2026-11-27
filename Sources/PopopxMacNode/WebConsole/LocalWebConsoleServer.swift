//
//  LocalWebConsoleServer.swift
//  PopopxMacNode — module 2: the loopback web console.
//
//  A hand-rolled HTTP/1.1 + Server-Sent-Events server on `Network.framework`
//  `NWListener`, bound to the loopback interface only, plus the complete
//  single-page wizard (Dark OLED glass, 中文 / EN) inlined as one Swift string
//  constant. Zero third-party dependencies, zero build steps, zero external
//  assets: the browser talks to this file and nothing else.
//
//  Design rules that hold the whole file together:
//
//  * The server owns no business state. Everything readable or mutable goes
//    through the frozen `NodeConsoleFacade` protocol, so the console can be
//    unit-tested against a fake facade and swapped without touching a route.
//  * The HTML is a static document. No Swift value is ever interpolated into it;
//    every number, label, path and QR payload arrives over the API. That keeps
//    the content-security-policy honest and keeps the template free of secrets.
//  * Parsing is incremental. TCP hands us arbitrary segments, so the request
//    parser is a state machine fed per `received` callback and never assumes one
//    read equals one request.
//  * Teardown is explicit. Every SSE connection owns a cancellable pump task and
//    an `AsyncStream.Continuation` that is `finish()`ed on drop, close or stop,
//    so the hub subscription (and its `onTermination` detach) can never leak.
//

import Foundation
import Network
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Console error surface

/// Errors the console can produce on its own, and the HTTP status each one maps
/// to. Facade errors are reported through the JSON `error` field instead,
/// because the browser never sees a Swift `Error`.
public enum WEBConsoleError: Error, Equatable, Sendable {
    case unauthorized
    case notFound(String)
    case addressNotLoopback(String)
    case portOutOfRange
    case listenerFailed(String)
    case notListening
    case alreadyListening
    case payloadTooLarge(limitBytes: Int, neededBytes: Int)
    case missingContentLength
    case malformedHeaders
    case oversizedHead(limitBytes: Int)
    case unsupportedEncoding(String)
    case targetTooLong(limitBytes: Int)
    case emptyBody
    case undecodableBody(typeName: String)
    case unsupportedMethod(String)
    case noPairingOffer
    case unknownEngine(String)
    case badEngine(String)
    case sendFailed(String)
    case connectionClosed
    case writerClosed

    var httpStatus: Int {
        switch self {
        case .unauthorized: return 401
        case .notFound: return 404
        case .payloadTooLarge: return 413
        case .missingContentLength: return 411
        case .unsupportedEncoding: return 501
        case .targetTooLong: return 414
        case .oversizedHead: return 400
        case .malformedHeaders, .emptyBody, .undecodableBody, .unknownEngine, .badEngine: return 400
        case .unsupportedMethod: return 405
        case .notListening: return 503
        case .noPairingOffer, .alreadyListening: return 409
        case .addressNotLoopback, .portOutOfRange, .listenerFailed, .sendFailed,
             .connectionClosed, .writerClosed: return 500
        }
    }

    var clientMessage: String {
        switch self {
        case .unauthorized:
            return "Missing or wrong console token. Open the URL the app printed, or send the \(NodeWire.consoleTokenHeader) header."
        case .notFound(let path):
            return "No console route at \(path)"
        case .addressNotLoopback(let detail):
            return "Refusing to serve outside loopback: \(detail)"
        case .portOutOfRange:
            return "Console port must be non-zero"
        case .listenerFailed(let detail):
            return "Console listener failed: \(detail)"
        case .notListening:
            return "Console is not listening yet"
        case .alreadyListening:
            return "Console is already listening"
        case .payloadTooLarge(let limit, let needed):
            return "Request body exceeds the \(limit) byte cap (declared \(needed))"
        case .missingContentLength:
            return "This request must carry a Content-Length header"
        case .malformedHeaders:
            return "Malformed HTTP request head"
        case .oversizedHead(let limit):
            return "Request head exceeds the \(limit) byte cap"
        case .unsupportedEncoding(let value):
            return "Transfer encoding \(value) is not supported: the console speaks identity only"
        case .targetTooLong(let limit):
            return "Request target exceeds the \(limit) byte cap"
        case .emptyBody:
            return "Request body is empty"
        case .undecodableBody(let typeName):
            return "Request body is not valid \(typeName) JSON"
        case .unsupportedMethod(let method):
            return "Method \(method) is not allowed on this route"
        case .noPairingOffer:
            return "The node has no pairing offer to serve yet"
        case .unknownEngine(let value):
            return "Unknown engine identifier: \(value)"
        case .badEngine(let detail):
            return "Malformed engine request: \(detail)"
        case .sendFailed(let detail):
            return "Write failed: \(detail)"
        case .connectionClosed, .writerClosed:
            return "Connection closed"
        }
    }
}

// MARK: - HTTP request value

/// One fully parsed request: head plus buffered body. Produced only by
/// `LocalWebConsoleServer.WEBWireParser`.
struct WEBHTTPRequest {
    let method: String
    let target: String
    let path: String
    let query: [URLQueryItem]
    let version: String
    let headers: [String: String]
    let body: Data

    /// `true` unless the client asked us to hang up, or is HTTP/1.0 without an
    /// explicit `Connection: keep-alive`.
    let keepAliveWanted: Bool

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    func queryValue(_ name: String) -> String? {
        query.first { $0.name == name }?.value
    }

    /// A request line longer than the cap cannot be echoed into a log, so this
    /// summary is deliberately method + path only.
    var summary: String {
        "\(method) \(path)"
    }
}

// MARK: - Response envelope

/// A response as it will go on the wire. Security headers are stamped by
/// `LocalWebConsoleServer.response(...)` so no route can forget one.
struct WEBHTTPResponse {
    let status: Int
    let reason: String
    let typeHeader: String?
    let headers: [(String, String)]
    let body: Data?

    /// `true` when the body must not be written (HEAD, 204, 304).
    var suppressBody: Bool {
        status == 204 || status == 304
    }

    var contentLength: Int { body?.count ?? 0 }

    static func empty(status: Int, reason: String, headers: [(String, String)] = []) -> WEBHTTPResponse {
        WEBHTTPResponse(status: status, reason: reason, typeHeader: nil, headers: headers, body: nil)
    }
}

// MARK: - Console SPA document

/// The entire wizard: HTML, CSS and vanilla ES2020 in one static document.
///
/// The literal is a raw multiline string (`#"""`), so JavaScript `$` + `{`,
/// regex backslashes and CSS escapes survive verbatim without a single Swift
/// escape sequence. The one substitution made on it is `/*PPX_LANGS*/[]`, and
/// its replacement is derived from `ConsoleLanguage.displayOrder` — a constant
/// of the binary, not of the machine — so the page is still byte-identical on
/// every launch, which is what makes the CSP below defensible.
enum WEBConsoleHTML {
    /// The console's language picker is generated rather than typed out again
    /// in JavaScript: `ConsoleLanguage` mirrors the POPOPX iOS app's
    /// `knownRegions`, and emitting it from Swift is what guarantees the phone
    /// and the node can never offer two different lists.
    /// `catalog` is computed by Swift rather than guessed in JavaScript, so the
    /// page and the node cannot disagree about which language reads which table.
    static let localeRegistryJavaScript: String = "[" + ConsoleLanguage.displayOrder.map { item in
        "{code:\"\(jsLiteral(item.rawValue))\",name:\"\(jsLiteral(item.nativeName))\",catalog:\"\(jsLiteral(item.catalogKey))\"}"
    }.joined(separator: ",") + "]"

    /// The model picker is generated from `ModelCatalog` rather than retyped in
    /// JavaScript, so the page can never offer a model the node will not resolve,
    /// and the copy travels as the same `Zh`/`Hant`/`En` triple the snapshot uses
    /// for engine names. Numbers stay numbers: the thresholds are the same integers
    /// `LLMModelOption.admission(memoryGB:)` compares against.
    static let modelRegistryJavaScript: String = {
        /// One object literal per entry. Joining the fields alone would emit
        /// `models:[a:1,b:2,...]`, which is a syntax error and takes the entire
        /// console script down with it.
        func entry(_ fields: [String]) -> String { "{" + fields.joined(separator: ",") + "}" }
        let models = ModelCatalog.options.map { option in
            entry([
                "id:\"\(jsLiteral(option.id))\"",
                "ref:\"\(jsLiteral(option.ollamaRef))\"",
                "name:\"\(jsLiteral(option.displayName))\"",
                "quant:\"\(jsLiteral(option.quantization))\"",
                "params:\(option.parameterBillions.map { String($0) } ?? "null")",
                "weight:\(option.weightGigabytes)",
                "ctx:\(option.contextOverheadGB)",
                "rec:\(option.recommendedMemoryGB)",
                "co:\(option.coResidentMemoryGB)",
                "swap:\(option.swapWarningMemoryGB)",
                "pull:\"\(jsLiteral(option.pullCommand(for: option.ollamaRef)))\"",
                "hint:\"\(jsLiteral(option.ggufCreateHint ?? ""))\"",
                "noteZh:\"\(jsLiteral(option.noteZh))\"",
                "noteHant:\"\(jsLiteral(TraditionalChinese.render(option.noteZh)))\"",
                "noteEn:\"\(jsLiteral(option.noteEn))\""
            ])
        }
        let admission = ModelAdmission.allCases.map { verdict in
            entry([
                "key:\"\(verdict.rawValue)\"",
                "zh:\"\(jsLiteral(verdict.titleZh))\"",
                "hant:\"\(jsLiteral(TraditionalChinese.render(verdict.titleZh)))\"",
                "en:\"\(jsLiteral(verdict.titleEn))\""
            ])
        }
        return "{models:[\(models.joined(separator: ","))],admission:[\(admission.joined(separator: ","))]}"
    }()

    /// The Traditional Chinese console is the page's own Simplified column, run
    /// through Apple's `Hans-Hant` transform. One hand-written table per script
    /// would drift the moment a key were added to only one of them; deriving it
    /// here means a new `zh` row is Traditional automatically, and
    /// `MacNodeContractTests` pins that both tables hold the same keys.
    static let traditionalCatalogJavaScript: String =
        "{" + traditionalRows.map { "\(jsLiteral($0.key)):\"\(jsLiteral($0.text))\"" }.joined(separator: ",") + "}"

    static let traditionalRows: [(key: String, text: String)] = {
        guard let pattern = try? NSRegularExpression(
            pattern: "[ \\t]*([A-Za-z][A-Za-z0-9_]*): \\{ zh: \"([^\"]*)\", en: "
        ) else { return [] }
        let range = NSRange(rawDocument.startIndex..<rawDocument.endIndex, in: rawDocument)
        return pattern.matches(in: rawDocument, range: range).compactMap { match in
            guard match.numberOfRanges == 3,
                  let keyRange = Range(match.range(at: 1), in: rawDocument),
                  let textRange = Range(match.range(at: 2), in: rawDocument)
            else { return nil }
            let text = String(rawDocument[textRange])
            guard text.rangeOfCharacter(from: TraditionalChinese.hanzi) != nil else { return nil }
            return (String(rawDocument[keyRange]), TraditionalChinese.render(text))
        }
    }()

    static let document: String = {
        rawDocument
            .replacingOccurrences(of: "/*PPX_LANGS*/[]", with: localeRegistryJavaScript)
            .replacingOccurrences(of: "/*PPX_HANT*/{}", with: traditionalCatalogJavaScript)
            .replacingOccurrences(of: "/*PPX_MODELS*/{models: [],admission: []}", with: modelRegistryJavaScript)
            // Last, so the generated Traditional rows carry the real scheme too.
            .replacingOccurrences(of: "/*PPX_SCHEME*/", with: NodeWire.invitationScheme)
    }()

    private static func jsLiteral(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    private static let rawDocument = #"""
<!DOCTYPE html>
<html lang="en" data-lang="system">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="dark">
<meta name="referrer" content="no-referrer">
<title>POPOPX Mac Node</title>
<style>
/* ---- design tokens ---------------------------------------------------- */
:root{
  --bg:#000;
  --panel:rgba(255,255,255,.035);
  --panel-strong:rgba(255,255,255,.06);
  --hair:rgba(255,255,255,.09);
  --hair-strong:rgba(255,255,255,.17);
  --ink:#f4f4f7;
  --dim:#a6a6b3;
  --mute:#7c7c89;
  --accent:#8b6cff;
  --accent-lift:#a892ff;
  --accent-deep:#5b3fd6;
  --ok:#3fd68f;
  --warn:#ffcc5c;
  --bad:#ff6b78;
  --info:#6cc5ff;
  --r-s:6px; --r-m:10px; --r-l:14px;
  --s1:4px; --s2:8px; --s3:12px; --s4:16px; --s5:24px; --s6:32px; --s7:48px;
  --fs-xs:11px; --fs-sm:12px; --fs-md:13px;
  --mono:ui-monospace,"SF Mono",SFMono-Regular,Menlo,monospace;
  --sans:-apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",sans-serif;
  --shadow:0 24px 60px -32px rgba(0,0,0,.95);
}
@media (min-width:760px){
  :root{--fs-xs:clamp(11px,.68vw,12px);--fs-sm:clamp(12px,.8vw,13.5px);--fs-md:clamp(13px,.92vw,15px)}
}
*,*::before,*::after{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{
  margin:0;min-height:100vh;
  background:var(--bg);color:var(--ink);
  font-family:var(--sans);font-size:var(--fs-md);line-height:1.5;
  font-variant-numeric:tabular-nums;
  -webkit-font-smoothing:antialiased;
}
/* Layered OLED glass: two very low-alpha light pools over true black. No
   rainbow gradients — depth comes from blur and hairlines, not hue travel. */
body::before{
  content:"";position:fixed;inset:0;z-index:-2;
  background:
    radial-gradient(70% 45% at 18% -5%,rgba(139,108,255,.13),transparent 70%),
    radial-gradient(55% 40% at 92% 8%,rgba(108,197,255,.07),transparent 68%),
    #000;
}
body::after{
  content:"";position:fixed;inset:0;z-index:-1;pointer-events:none;opacity:.04;
  background-image:repeating-linear-gradient(0deg,#fff 0 1px,transparent 1px 3px);
  background-size:100% 3px;
}
::selection{background:rgba(139,108,255,.35)}
:focus-visible{outline:2px solid var(--accent-lift);outline-offset:2px}
h1,h2,h3,h4{margin:0;font-weight:650;letter-spacing:-.015em}
h3{font-size:clamp(15px,1.15vw,18px)}
h4{font-size:var(--fs-md);color:var(--ink)}
p{margin:0}
button{font:inherit;color:inherit;background:none;border:0;padding:0;cursor:pointer}
input,select,textarea{font:inherit;color:var(--ink)}
input::placeholder{color:var(--mute)}
a{color:var(--accent-lift)}
.mono{font-family:var(--mono);font-size:.92em;letter-spacing:-.01em}
.dim{color:var(--dim)}
.mute{color:var(--mute)}
.sr{position:absolute;width:1px;height:1px;overflow:hidden;clip-path:inset(50%);white-space:nowrap}
[hidden]{display:none !important}
/* ---- surfaces --------------------------------------------------------- */
.panel{
  background:var(--panel);
  border:1px solid var(--hair);
  border-radius:var(--r-l);
  -webkit-backdrop-filter:blur(24px) saturate(155%);
  backdrop-filter:blur(24px) saturate(155%);
  padding:var(--s4);
}
.hair{height:1px;background:var(--hair);border:0;margin:var(--s3) 0}
.panel__head{display:flex;align-items:baseline;justify-content:space-between;gap:var(--s3);margin-bottom:var(--s3)}
.panel__sub{color:var(--mute);font-size:var(--fs-xs);margin-top:calc(var(--s2) * -1 + 2px);margin-bottom:var(--s3)}
/* ---- chrome ----------------------------------------------------------- */
.app{max-width:1180px;margin:0 auto;padding:var(--s4) var(--s4) var(--s7)}
.topbar{
  position:sticky;top:0;z-index:30;
  display:flex;flex-wrap:wrap;align-items:center;gap:var(--s3) var(--s4);
  padding:var(--s3) var(--s4);
  background:rgba(0,0,0,.55);
  border:1px solid var(--hair);
  border-radius:var(--r-l);
  -webkit-backdrop-filter:blur(30px) saturate(160%);
  backdrop-filter:blur(30px) saturate(160%);
  box-shadow:var(--shadow);
}
.brand{display:flex;align-items:center;gap:var(--s3);min-width:0;flex:1 1 auto}
.brand__mark{width:34px;height:34px;flex:0 0 auto;color:var(--accent-lift)}
.brand__mark svg{display:block;width:100%;height:100%}
.brand__text{display:flex;flex-direction:column;min-width:0}
.brand__name{font-size:clamp(15px,1.2vw,19px);font-weight:700;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.brand__sub{font-size:var(--fs-xs);color:var(--mute);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.brand__claim{font-size:var(--fs-xs);font-weight:600;letter-spacing:.01em;color:var(--accent-lift);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
/* Measured at 360px: the Simplified and Traditional claim needs 261px inside a
   248px box, so the ellipsis would cut the sentence's own full stop off the
   brand line. Wrapping costs one line of sticky header and loses nothing. */
@media (max-width:479px){.brand__claim{white-space:normal;line-height:1.35}}
.chip{
  display:inline-flex;align-items:center;gap:var(--s2);
  padding:3px var(--s2);border:1px solid var(--hair);border-radius:999px;
  background:rgba(255,255,255,.04);font-size:var(--fs-xs);color:var(--dim);
  white-space:nowrap;
}
.chip--ghost{background:none}
.topbar__right{display:flex;align-items:center;gap:var(--s2);flex:0 0 auto}
.dot{width:9px;height:9px;border-radius:50%;background:var(--mute);flex:0 0 auto;box-shadow:0 0 0 3px rgba(255,255,255,.05)}
.dot[data-state="live"]{background:var(--ok);box-shadow:0 0 0 3px rgba(63,214,143,.16)}
.dot[data-state="retry"]{background:var(--warn);box-shadow:0 0 0 3px rgba(255,204,92,.16)}
.dot[data-state="offline"]{background:var(--bad);box-shadow:0 0 0 3px rgba(255,107,120,.16)}
.dot[data-state="connecting"]{background:var(--accent-lift);box-shadow:0 0 0 3px rgba(139,108,255,.18)}
@media (prefers-reduced-motion:no-preference){
  .dot[data-state="live"]{animation:pulse 2.4s ease-in-out infinite}
  .dot[data-state="connecting"],.dot[data-state="retry"]{animation:pulse 1.4s ease-in-out infinite}
}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.4}}
#clock{font-family:var(--mono);font-size:var(--fs-sm);color:var(--dim);letter-spacing:.02em}
.lang{position:relative;display:flex;align-items:center}
.lang__select{
  appearance:none;-webkit-appearance:none;
  padding:var(--s1) 26px var(--s1) 10px;
  font-family:var(--mono);font-size:var(--fs-xs);color:var(--dim);
  background:#0e0e12;border:1px solid var(--hair);border-radius:var(--r-s);
  cursor:pointer;max-width:176px
}
.lang__select:hover{color:var(--ink);border-color:var(--hair-strong)}
.lang__select:focus-visible{outline:2px solid var(--accent);outline-offset:1px}
.lang__caret{position:absolute;right:9px;pointer-events:none;color:var(--mute);font-size:var(--fs-xs)}
.lang__select option{background:#0e0e12;color:var(--ink)}
/* ---- step rail -------------------------------------------------------- */
.rail{display:flex;gap:var(--s2);margin:var(--s4) 0 var(--s3)}
.rail__btn{
  flex:1 1 0;min-width:0;text-align:left;
  display:flex;align-items:center;gap:var(--s2);
  padding:var(--s3);border:1px solid var(--hair);border-radius:var(--r-m);
  background:rgba(255,255,255,.02);color:var(--dim);
  transition:border-color .18s ease,background .18s ease,color .18s ease,transform .18s ease;
}
@media (prefers-reduced-motion:no-preference){.rail__btn:hover{transform:translateY(-1px)}}
.rail__btn.is-on{border-color:rgba(139,108,255,.5);background:rgba(139,108,255,.12);color:var(--ink)}
.rail__idx{font-family:var(--mono);font-size:var(--fs-xs);color:var(--mute)}
.rail__btn.is-on .rail__idx{color:var(--accent-lift)}
.rail__name{font-size:var(--fs-sm);font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.rail__badge{margin-left:auto;width:18px;height:18px;flex:0 0 auto}
.rail__badge svg{display:block;width:18px;height:18px}
.rail__btn[data-status="done"] .rail__badge{color:var(--ok)}
.rail__btn[data-status="run"] .rail__badge{color:var(--accent-lift)}
.rail__btn[data-status="wait"] .rail__badge{color:var(--bad)}
.rail__btn[data-status="todo"] .rail__badge{color:var(--mute)}
/* ---- grids ------------------------------------------------------------ */
.grid{display:grid;gap:var(--s3)}
.grid--stats{grid-template-columns:repeat(auto-fit,minmax(196px,1fr))}
.grid--split{grid-template-columns:1fr}
.grid--log{grid-template-columns:1fr}
@media (min-width:880px){
  .grid--split{grid-template-columns:minmax(0,380px) minmax(0,1fr)}
  .grid--log{grid-template-columns:minmax(0,420px) minmax(0,1fr)}
}
.stack{display:flex;flex-direction:column;gap:var(--s3)}
.stat{
  padding:var(--s3);border:1px solid var(--hair);border-radius:var(--r-m);
  background:rgba(255,255,255,.025);
  display:flex;flex-direction:column;gap:var(--s1);min-width:0;
}
.stat__k{font-size:var(--fs-xs);color:var(--mute);text-transform:uppercase;letter-spacing:.08em}
.stat__v{font-size:clamp(19px,1.7vw,26px);font-weight:700;letter-spacing:-.02em;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.stat__n{font-size:var(--fs-xs);color:var(--mute);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.stat__v--sm{font-size:clamp(15px,1.2vw,19px)}
/* ---- buttons ---------------------------------------------------------- */
.btn{
  display:inline-flex;align-items:center;justify-content:center;gap:var(--s2);
  padding:9px 14px;border:1px solid var(--hair-strong);border-radius:var(--r-m);
  background:rgba(255,255,255,.06);color:var(--ink);font-size:var(--fs-sm);font-weight:600;
  transition:background .16s ease,border-color .16s ease,transform .16s ease,opacity .16s ease;
  white-space:nowrap;
}
@media (prefers-reduced-motion:no-preference){
  .btn:hover{background:rgba(255,255,255,.1)}
  .btn:active{transform:translateY(1px)}
}
.btn--primary{
  background:linear-gradient(180deg,var(--accent-lift),var(--accent-deep));
  border-color:transparent;color:#fff;
  box-shadow:0 10px 26px -12px rgba(139,108,255,.85);
  padding:12px 18px;font-size:var(--fs-md);
}
@media (prefers-reduced-motion:no-preference){
  .btn--primary:hover{filter:brightness(1.07)}
}
.btn--ghost{background:none;border-color:var(--hair);color:var(--dim);font-weight:500}
.btn--mini{padding:5px 9px;font-size:var(--fs-xs);font-weight:500;border-radius:var(--r-s)}
.btn--tiny{padding:3px 7px;font-size:var(--fs-xs);font-weight:500;border-radius:var(--r-s);color:var(--mute);border:1px solid var(--hair);background:none}
.btn[disabled],.btn.is-disabled{opacity:.45;pointer-events:none}
.btn-row{display:flex;flex-wrap:wrap;gap:var(--s2);align-items:center}
/* ---- forms ------------------------------------------------------------ */
.field{display:flex;flex-direction:column;gap:var(--s1);min-width:0}
.field__label{font-size:var(--fs-xs);color:var(--dim)}
.field__note{font-size:var(--fs-xs);color:var(--mute)}
.field__err{font-size:var(--fs-xs);color:var(--bad)}
input[type=text],input[type=password],input[type=number],input[type=url],select,textarea{
  width:100%;padding:8px 10px;
  background:rgba(255,255,255,.05);border:1px solid var(--hair);border-radius:var(--r-s);
  font-size:var(--fs-sm);
  transition:border-color .16s ease,background .16s ease;
}
input:focus,select:focus,textarea:focus{border-color:rgba(139,108,255,.6);background:rgba(139,108,255,.07);outline:none}
textarea{min-height:66px;resize:vertical;font-family:var(--mono);font-size:var(--fs-xs);line-height:1.6}
.fields{display:grid;gap:var(--s3);grid-template-columns:repeat(auto-fit,minmax(168px,1fr))}
.fields--wide{grid-template-columns:repeat(auto-fit,minmax(240px,1fr))}
.list{display:flex;flex-direction:column;gap:var(--s2)}
.list__row{display:flex;gap:var(--s2);align-items:center}
.list__row input{flex:1 1 auto;min-width:0}
/* switch */
.switch{
  position:relative;width:46px;height:26px;flex:0 0 auto;
  border-radius:999px;border:1px solid var(--hair-strong);
  background:rgba(255,255,255,.08);transition:background .18s ease,border-color .18s ease;
}
.switch__knob{
  position:absolute;top:2px;left:2px;width:20px;height:20px;border-radius:50%;
  background:#e9e9ef;transition:transform .18s ease;
}
@media (prefers-reduced-motion:reduce){.switch,.switch__knob{transition:none}}
.switch[aria-checked="true"]{background:var(--accent);border-color:transparent}
.switch[aria-checked="true"] .switch__knob{transform:translateX(20px);background:#fff}
.switch.is-pending{opacity:.55}
/* checkbox */
.check{display:flex;align-items:center;gap:var(--s2);font-size:var(--fs-sm);color:var(--dim);cursor:pointer}
.check input{width:16px;height:16px;accent-color:var(--accent);flex:0 0 auto}
/* segmented weekday picker */
.weekdays{display:flex;gap:3px;flex-wrap:wrap}
.weekdays button{
  width:26px;height:24px;border:1px solid var(--hair);border-radius:var(--r-s);
  font-size:var(--fs-xs);color:var(--mute);background:rgba(255,255,255,.03);
}
.weekdays button.is-on{background:rgba(139,108,255,.22);border-color:rgba(139,108,255,.55);color:var(--ink);font-weight:650}
/* ---- tables ----------------------------------------------------------- */
.table{width:100%;border-collapse:collapse;font-size:var(--fs-sm)}
.table th{
  text-align:left;font-weight:600;color:var(--mute);font-size:var(--fs-xs);
  text-transform:uppercase;letter-spacing:.07em;padding:0 var(--s2) var(--s2);
  border-bottom:1px solid var(--hair);white-space:nowrap;
}
.table td{padding:var(--s2);border-bottom:1px solid rgba(255,255,255,.055);vertical-align:top;color:var(--dim)}
.table tr:last-child td{border-bottom:0}
.table tbody tr.is-active td{color:var(--ink);background:rgba(139,108,255,.1)}
.table tbody tr.is-active td:first-child{box-shadow:inset 2px 0 0 var(--accent-lift)}
.table--rows td{color:var(--ink)}
.tscroll{overflow-x:auto;-webkit-overflow-scrolling:touch}
.cell-strong{color:var(--ink);font-weight:600}
.tag{display:inline-block;padding:2px 6px;border-radius:999px;border:1px solid var(--hair);font-size:var(--fs-xs);color:var(--dim)}
.tag--ok{border-color:rgba(63,214,143,.4);color:var(--ok)}
.tag--bad{border-color:rgba(255,107,120,.4);color:var(--bad)}
.tag--accent{border-color:rgba(139,108,255,.45);color:var(--accent-lift)}
.tag--warn{border-color:rgba(255,204,92,.4);color:var(--warn)}
.tag--off{color:var(--mute)}
/* ---- pills ------------------------------------------------------------ */
.pills{display:flex;flex-wrap:wrap;gap:var(--s2)}
.pill{
  display:inline-flex;align-items:center;gap:6px;
  padding:5px 9px;border-radius:999px;border:1px solid var(--hair);
  font-size:var(--fs-xs);color:var(--dim);background:rgba(255,255,255,.03);
}
.pill__led{width:7px;height:7px;border-radius:50%;background:var(--ok);flex:0 0 auto}
.pill.is-missing{color:var(--mute);border-style:dashed}
.pill.is-missing .pill__led{background:var(--bad)}
.pill__ver{font-family:var(--mono);color:var(--mute)}
/* ---- checklist -------------------------------------------------------- */
.checklist{list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:2px}
.checklist li{display:flex;align-items:flex-start;gap:var(--s2);padding:var(--s2);border-radius:var(--r-s)}
.checklist li:nth-child(odd){background:rgba(255,255,255,.022)}
.checklist__ico{width:18px;height:18px;flex:0 0 auto;margin-top:1px;color:var(--mute)}
.checklist__ico svg{display:block;width:18px;height:18px}
.checklist li[data-state="done"] .checklist__ico{color:var(--ok)}
.checklist li[data-state="running"] .checklist__ico{color:var(--accent-lift)}
.checklist li[data-state="failed"] .checklist__ico{color:var(--bad)}
.checklist li[data-state="skipped"] .checklist__ico{color:var(--mute)}
.checklist__body{display:flex;flex-direction:column;gap:2px;min-width:0;flex:1 1 auto}
.checklist__title{font-size:var(--fs-sm);color:var(--ink)}
.checklist__detail{font-size:var(--fs-xs);color:var(--mute);word-break:break-word}
.checklist__bar{height:2px;border-radius:2px;background:rgba(255,255,255,.09);overflow:hidden;margin-top:3px}
.checklist__bar i{display:block;height:100%;background:var(--accent);transition:width .3s ease}
@media (prefers-reduced-motion:reduce){.checklist__bar i{transition:none}}
/* ---- terminal --------------------------------------------------------- */
.term{
  display:flex;flex-direction:column;
  height:clamp(260px,32vh,420px);
  border:1px solid var(--hair);border-radius:var(--r-m);
  background:rgba(0,0,0,.55);overflow:hidden;
}
.term__head{display:flex;align-items:center;gap:var(--s2);flex-wrap:wrap;padding:var(--s2) var(--s3);border-bottom:1px solid var(--hair)}
.term__title{font-family:var(--mono);font-size:var(--fs-xs);color:var(--mute);text-transform:uppercase;letter-spacing:.1em;margin-right:auto}
.term select{width:auto;padding:3px 6px;font-size:var(--fs-xs)}
.term__body{flex:1 1 auto;overflow-y:auto;padding:var(--s2) var(--s3);font-family:var(--mono);font-size:var(--fs-xs);line-height:1.65;scrollbar-width:thin}
.term__body::-webkit-scrollbar{width:8px;height:8px}
.term__body::-webkit-scrollbar-thumb{background:rgba(255,255,255,.16);border-radius:4px}
.term__foot{display:flex;align-items:center;gap:var(--s2);padding:var(--s1) var(--s3);border-top:1px solid var(--hair);min-height:26px}
.term__foot .mute{font-size:var(--fs-xs)}
.line{display:flex;gap:var(--s2);white-space:pre-wrap;word-break:break-word}
.line__t{color:#4f4f5c;flex:0 0 auto}
.line__g{flex:0 0 auto;width:14px;text-align:center}
.line__c{color:#5a5a68;flex:0 0 auto}
.line__m{color:#d5d5dd;min-width:0}
.line[data-level="success"] .line__g{color:var(--ok)}
.line[data-level="info"] .line__g{color:var(--info)}
.line[data-level="notice"] .line__g{color:var(--dim)}
.line[data-level="debug"] .line__g{color:#5a5a68}
.line[data-level="warning"] .line__g,.line[data-level="warning"] .line__m{color:var(--warn)}
.line[data-level="error"] .line__g,.line[data-level="error"] .line__m{color:var(--bad)}
/* ---- gauge ------------------------------------------------------------ */
.gauge{position:relative;width:100%;max-width:236px;aspect-ratio:1;margin-inline:auto}
.gauge svg{display:block;width:100%;height:100%}
.gauge__ring{fill:none;stroke-width:12}
.gauge__bg{stroke:rgba(255,255,255,.07)}
.gauge__arc{stroke:var(--accent);stroke-linecap:round;transition:stroke-dashoffset .9s cubic-bezier(.22,.61,.36,1)}
@media (prefers-reduced-motion:reduce){.gauge__arc{transition:none}}
.gauge__arc--outer{stroke:rgba(139,108,255,.28)}
.gauge__label{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:2px;pointer-events:none}
.gauge__pct{font-size:clamp(24px,2.4vw,34px);font-weight:700;letter-spacing:-.03em}
.gauge__cap{font-size:var(--fs-xs);color:var(--mute)}
.gauge__val{font-family:var(--mono);font-size:var(--fs-xs);color:var(--dim)}
/* ---- pairing ---------------------------------------------------------- */
.qr-wrap{display:flex;flex-direction:column;gap:var(--s2);align-items:center;width:100%;padding:var(--s2)}
.qr-box{
  position:relative;width:100%;max-width:288px;aspect-ratio:1;
  border:1px solid var(--hair-strong);border-radius:var(--r-m);
  background:rgba(255,255,255,.04);overflow:hidden;
  display:grid;place-items:center;
}
.qr-box img{width:100%;height:auto;aspect-ratio:1;object-fit:contain;background:#fff;border-radius:var(--r-s);display:block;image-rendering:pixelated}
.code{
  font-family:var(--mono);font-size:var(--fs-xs);line-height:1.7;
  padding:var(--s3);border:1px solid var(--hair);border-radius:var(--r-m);
  background:rgba(0,0,0,.45);word-break:break-all;user-select:all;-webkit-user-select:all;
  color:var(--ink);max-height:112px;overflow:auto;
}
.step{display:flex;flex-direction:column;gap:var(--s4)}
@media (prefers-reduced-motion:no-preference){.step{animation:step-in .32s cubic-bezier(.22,.61,.36,1) both}}
@keyframes step-in{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:none}}
.countdown{font-family:var(--mono);font-size:clamp(17px,1.5vw,22px);font-weight:650;color:var(--ink)}
.countdown.is-out{color:var(--bad)}
.pair-success{display:flex;flex-direction:column;gap:var(--s3);align-items:flex-start}
.pair-success__title{display:flex;align-items:center;gap:var(--s2);font-size:clamp(15px,1.2vw,19px);font-weight:700;color:var(--ok)}
.pair-success__title svg{width:20px;height:20px;flex:0 0 auto}
@media (prefers-reduced-motion:no-preference){
  .pair-root.is-done{animation:tunnel-in .55s cubic-bezier(.2,.8,.2,1) both}
}
@keyframes tunnel-in{
  from{opacity:.25;transform:scale(.985);box-shadow:0 0 0 0 rgba(63,214,143,0)}
  to{opacity:1;transform:scale(1);box-shadow:0 0 0 1px rgba(63,214,143,.28)}
}
/* ---- engines ---------------------------------------------------------- */
.engines{display:grid;gap:var(--s2);grid-template-columns:repeat(auto-fit,minmax(320px,1fr))}
.engine{
  display:flex;flex-direction:column;gap:var(--s2);
  padding:var(--s3);border:1px solid var(--hair);border-radius:var(--r-m);
  background:rgba(255,255,255,.025);
  transition:border-color .18s ease,background .18s ease;
}
.engine.is-on{border-color:rgba(139,108,255,.38);background:rgba(139,108,255,.07)}
.engine.is-busy{border-color:rgba(255,204,92,.4)}
.engine__top{display:flex;align-items:flex-start;gap:var(--s3)}
.engine__ico{width:30px;height:30px;flex:0 0 auto;color:var(--accent-lift)}
.engine__ico svg{display:block;width:100%;height:100%}
.engine__id{display:flex;flex-direction:column;gap:1px;min-width:0;flex:1 1 auto}
.engine__name{font-size:var(--fs-md);font-weight:650;color:var(--ink)}
.engine__alt{font-size:var(--fs-xs);color:var(--mute)}
.engine__tag{font-size:var(--fs-xs);color:var(--dim)}
.engine__meta{display:flex;flex-wrap:wrap;gap:var(--s2);align-items:center;font-family:var(--mono);font-size:var(--fs-xs);color:var(--mute)}
.engine__meta i{font-style:normal;color:var(--dim)}
.engine__foot{display:flex;align-items:center;gap:var(--s2);flex-wrap:wrap}
.engine__ref{font-family:var(--mono);font-size:var(--fs-xs);color:#4f4f5c;margin-left:auto}
/* ---- privacy bridges -------------------------------------------------- */
/* One card per proposal: the left rule carries its state, because the thing an
   operator scans for on this page is "what is waiting for me right now". */
.pv{display:flex;flex-direction:column;gap:var(--s3)}
.pv-card{
  display:flex;flex-direction:column;gap:var(--s2);
  padding:var(--s3);border:1px solid var(--hair);border-left:2px solid var(--accent);
  border-radius:var(--r-m);background:rgba(255,255,255,.025);
}
.pv-card.is-spent{border-left-color:var(--hair-strong);opacity:.72}
.pv-card.is-live{border-left-color:var(--ok)}
.pv-top{display:flex;align-items:center;gap:var(--s2);flex-wrap:wrap}
.pv-title{font-size:var(--fs-sm);font-weight:650;color:var(--ink)}
.pv-meta{font-family:var(--mono);font-size:var(--fs-xs);color:var(--mute)}
.pv-line{font-size:var(--fs-xs);color:var(--dim);word-break:break-word}
.pv-acts{display:flex;gap:var(--s2);flex-wrap:wrap;align-items:center}
.pv-ttl{margin-left:auto;font-family:var(--mono);font-size:var(--fs-xs);color:var(--mute)}
.pv-ttl.is-soon{color:var(--warn)}
.pv-log{display:flex;flex-direction:column;gap:var(--s1);max-height:280px;overflow:auto;font-family:var(--mono);font-size:var(--fs-xs)}
.pv-log__row{display:flex;gap:var(--s2);align-items:baseline;border-bottom:1px solid var(--hair);padding-bottom:3px}
.pv-log__at{flex:0 0 auto;color:#4f4f5c}
.pv-log__tx{min-width:0;color:var(--dim);word-break:break-word}
.dot{width:8px;height:8px;border-radius:50%;flex:0 0 auto;background:var(--mute)}
.dot--ok{background:var(--ok)}
.dot--bad{background:var(--bad)}
.dot--off{background:var(--mute)}
.btn--ok{border-color:rgba(63,214,143,.45);color:var(--ok)}
.btn--bad{border-color:rgba(255,107,120,.4);color:var(--bad)}
/* The second click of the confirmation gate: an armed button says so, in the
   warning colour, and a poll that rebuilds the panel always drops the arm. */
.btn.is-arm{background:rgba(255,204,92,.16);border-color:rgba(255,204,92,.55);color:var(--warn)}
/* ---- states ----------------------------------------------------------- */
.empty,.error{
  display:flex;flex-direction:column;align-items:center;justify-content:center;gap:var(--s2);
  padding:var(--s5) var(--s3);text-align:center;color:var(--mute);
  border:1px dashed var(--hair);border-radius:var(--r-m);font-size:var(--fs-sm);
}
.error{border-color:rgba(255,107,120,.35);border-style:solid;color:var(--bad)}
.error .btn{margin-top:var(--s1)}
.skeleton{
  background:linear-gradient(90deg,rgba(255,255,255,.045),rgba(255,255,255,.1),rgba(255,255,255,.045));
  background-size:240% 100%;border-radius:var(--r-s);min-height:14px;
}
@media (prefers-reduced-motion:no-preference){.skeleton{animation:sh 1.5s linear infinite}}
@keyframes sh{from{background-position:130% 0}to{background-position:-130% 0}}
.skel-stack{display:flex;flex-direction:column;gap:var(--s2)}
.banner{
  display:flex;align-items:center;gap:var(--s2);flex-wrap:wrap;
  padding:var(--s2) var(--s3);border-radius:var(--r-m);
  border:1px solid rgba(255,204,92,.35);background:rgba(255,204,92,.08);color:var(--warn);
  font-size:var(--fs-sm);margin-bottom:var(--s3);
}
/* ---- save bar --------------------------------------------------------- */
.savebar{
  position:sticky;bottom:0;z-index:20;
  display:flex;align-items:center;gap:var(--s3);flex-wrap:wrap;
  margin-top:var(--s4);padding:var(--s3) var(--s4);
  background:rgba(0,0,0,.66);
  border:1px solid var(--hair-strong);border-radius:var(--r-l);
  -webkit-backdrop-filter:blur(28px) saturate(160%);
  backdrop-filter:blur(28px) saturate(160%);
  box-shadow:var(--shadow);
}
.savebar__state{display:flex;flex-direction:column;gap:1px;flex:1 1 auto;min-width:0}
.savebar__text{font-size:var(--fs-sm);color:var(--dim)}
.savebar__text.is-dirty{color:var(--warn)}
.savebar__rev{font-family:var(--mono);font-size:var(--fs-xs);color:var(--mute)}
/* ---- drawer ----------------------------------------------------------- */
.drawer{margin-top:var(--s4);border:1px solid var(--hair);border-radius:var(--r-l);background:rgba(255,255,255,.02);overflow:hidden}
.drawer__head{display:flex;align-items:center;gap:var(--s2);padding:var(--s3) var(--s4);cursor:pointer;width:100%;text-align:left}
.drawer__head h3{font-size:var(--fs-sm);font-weight:600;color:var(--dim);margin-right:auto}
.drawer__head svg{width:16px;height:16px;color:var(--mute);transition:transform .18s ease}
@media (prefers-reduced-motion:reduce){.drawer__head svg{transition:none}}
.drawer.is-open .drawer__head svg{transform:rotate(90deg)}
.drawer__body{padding:0 var(--s4) var(--s4);display:grid;gap:var(--s3);grid-template-columns:1fr}
@media (min-width:900px){.drawer__body{grid-template-columns:minmax(0,1fr) minmax(0,1fr)}}
pre.raw{
  margin:0;padding:var(--s3);border:1px solid var(--hair);border-radius:var(--r-m);
  background:rgba(0,0,0,.5);font-family:var(--mono);font-size:var(--fs-xs);line-height:1.55;
  max-height:320px;overflow:auto;color:#c8c8d2;white-space:pre-wrap;word-break:break-word;
}
/* ---- toasts ----------------------------------------------------------- */
#toasts{position:fixed;right:var(--s4);bottom:var(--s4);z-index:50;display:flex;flex-direction:column;gap:var(--s2);max-width:min(380px,90vw)}
.toast{
  display:flex;align-items:flex-start;gap:var(--s2);
  padding:var(--s3);border:1px solid var(--hair-strong);border-radius:var(--r-m);
  background:rgba(16,16,20,.92);color:var(--ink);font-size:var(--fs-sm);
  -webkit-backdrop-filter:blur(20px) saturate(150%);
  backdrop-filter:blur(20px) saturate(150%);
  box-shadow:var(--shadow);
}
@media (prefers-reduced-motion:no-preference){.toast{animation:toast-in .22s ease-out both}}
@keyframes toast-in{from{opacity:0;transform:translateY(8px)}to{opacity:1;transform:none}}
.toast[data-kind="ok"]{border-color:rgba(63,214,143,.45)}
.toast[data-kind="err"]{border-color:rgba(255,107,120,.5)}
.toast[data-kind="warn"]{border-color:rgba(255,204,92,.45)}
.toast__x{margin-left:auto;color:var(--mute);font-size:var(--fs-xs);padding:0 var(--s1)}
.brandnote{margin-top:var(--s5);padding:var(--s3) var(--s4);border:1px solid var(--hair);border-radius:var(--r-l);background:rgba(255,255,255,.02);display:flex;flex-direction:column;gap:var(--s2)}
.brandnote__head{display:flex;flex-wrap:wrap;align-items:baseline;gap:var(--s1) var(--s3);font-size:var(--fs-xs);line-height:1.5;color:var(--dim);overflow-wrap:anywhere}
.brandnote__pos{font-weight:600;color:var(--accent-lift);letter-spacing:.01em}
.brandnote__slogan::before{content:"·";margin-right:var(--s2);color:var(--mute)}
.brandnote__mission,.brandnote__role{font-size:var(--fs-xs);line-height:1.6;color:var(--mute);overflow-wrap:anywhere}
footer.app__foot{margin-top:var(--s5);padding-top:var(--s3);border-top:1px solid var(--hair);display:flex;flex-wrap:wrap;gap:var(--s2) var(--s4);align-items:center;font-size:var(--fs-xs);color:var(--mute)}
</style>
</head>
<body>
<div class="app">

<header class="topbar">
  <div class="brand">
    <span class="brand__mark" aria-hidden="true">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">
        <path d="M12 2.6 4.6 5.4v6.1c0 4.4 3 8.2 7.4 9.9 4.4-1.7 7.4-5.5 7.4-9.9V5.4L12 2.6z"/>
        <path d="M8.6 13.4h2.2l1.1-3.1 1.6 5 1-1.9h2"/>
      </svg>
    </span>
    <span class="brand__text">
      <h1 class="brand__name" id="node-name">POPOPX Mac Node</h1>
      <span class="brand__claim" data-i18n="brandClaim"></span>
      <span class="brand__sub" data-i18n="brandSub"></span>
      <span class="brand__sub mono" id="node-ref"></span>
    </span>
  </div>
  <div class="chip" title="POPOPX-XXXX" id="chip-mem" data-i18n="loadingShort"></div>
  <div class="chip chip--ghost mono" id="serial-ref"></div>
  <div class="topbar__right">
    <span id="clock" aria-live="off">--:--:--</span>
    <button class="chip chip--ghost" id="conn" data-state="connecting" title="连接中">
      <span class="dot" id="dot" data-state="connecting"></span>
      <span id="conn-text" data-i18n="connecting"></span>
    </button>
    <div class="lang" role="group" data-i18n-aria="langGroup" aria-label="Console language">
      <select class="lang__select" id="lang-select" onchange="PPX.setLang(this.value)"></select>
      <span class="lang__caret" aria-hidden="true">▾</span>
    </div>
  </div>
</header>

<div id="offline" class="banner" hidden>
  <span data-i18n="offlineBanner"></span>
  <button class="btn btn--mini" onclick="PPX.retry()" data-i18n="retry"></button>
</div>

<nav class="rail" data-i18n-aria="railAria" aria-label="Setup steps">
  <button class="rail__btn is-on" id="rail-1" data-step="1" data-status="todo" onclick="PPX.step(1)">
    <span class="rail__idx">01</span>
    <span class="rail__name" data-i18n="s1"></span>
    <span class="rail__badge" id="railbadge-1"></span>
  </button>
  <button class="rail__btn" id="rail-2" data-step="2" data-status="todo" onclick="PPX.step(2)">
    <span class="rail__idx">02</span>
    <span class="rail__name" data-i18n="s2"></span>
    <span class="rail__badge" id="railbadge-2"></span>
  </button>
  <button class="rail__btn" id="rail-3" data-step="3" data-status="todo" onclick="PPX.step(3)">
    <span class="rail__idx">03</span>
    <span class="rail__name" data-i18n="s3"></span>
    <span class="rail__badge" id="railbadge-3"></span>
  </button>
  <button class="rail__btn" id="rail-4" data-step="4" data-status="todo" onclick="PPX.step(4)">
    <span class="rail__idx">04</span>
    <span class="rail__name" data-i18n="s4"></span>
    <span class="rail__badge" id="railbadge-4"></span>
  </button>
  <button class="rail__btn" id="rail-5" data-step="5" data-status="todo" onclick="PPX.step(5)">
    <span class="rail__idx">05</span>
    <span class="rail__name" data-i18n="s5"></span>
    <span class="rail__badge" id="railbadge-5"></span>
  </button>
</nav>

<main>
<section class="step" id="step-1">
  <div class="panel">
    <div class="panel__head">
      <h2><span data-i18n="s1Title"></span></h2>
      <span class="tag tag--off" id="install-badge" data-i18n="loadingShort"></span>
    </div>
    <p class="panel__sub" data-i18n="s1Desc"></p>
    <div class="grid grid--stats" id="stats"></div>
  </div>

  <div class="grid grid--split" style="margin-top:12px">
    <div class="stack">
      <section class="panel">
        <div class="panel__head"><h3 data-i18n="memTitle"></h3><span class="tag" id="tier-tag">—</span></div>
        <div id="gauge"></div>
        <hr class="hair">
        <div class="btn-row">
          <button class="btn btn--primary" id="btn-deploy" onclick="PPX.installStart()">
            <span data-i18n="deploy"></span>
          </button>
          <button class="btn" id="btn-cancel" onclick="PPX.installCancel()" hidden><span data-i18n="cancelInstall"></span></button>
        </div>
        <p class="field__note" id="deploy-hint" data-i18n="idleHint" style="margin-top:8px"></p>
      </section>

      <section class="panel">
        <div class="panel__head"><h3 data-i18n="toolchainTitle"></h3></div>
        <div class="pills" id="toolchain"></div>
      </section>
    </div>

    <div class="stack">
      <section class="panel">
        <div class="panel__head"><h3 data-i18n="planTitle"></h3><span class="tag tag--accent" id="plan-llm">—</span></div>
        <div class="tscroll"><table class="table" id="ladder"></table></div>
        <p class="field__note" id="plan-note" style="margin-top:8px"></p>
        <hr class="hair">
        <span class="field__label" data-i18n="modelTitle"></span>
        <select id="model-select" onchange="PPX.modelPick()"></select>
        <div class="engine__meta" id="model-live"></div>
        <p class="field__note" id="model-note"></p>
        <button class="btn btn--mini" id="model-copy" onclick="PPX.modelCopy()" hidden></button>
      </section>

      <section class="panel">
        <div class="panel__head"><h3 data-i18n="stepsTitle"></h3></div>
        <ul class="checklist" id="checklist"></ul>
      </section>

      <section class="panel">
        <div class="panel__head"><h3 data-i18n="logTitle"></h3></div>
        <div class="term">
          <div class="term__head">
            <span class="term__title">node · install.log</span>
            <label class="sr" for="log-filter" data-i18n="levelFilter"></label>
            <select id="log-filter" onchange="PPX.logFilter()">
              <option value="all" data-i18n="filterAll"></option>
              <option value="info" data-i18n="filterInfo"></option>
              <option value="notice" data-i18n="filterNotice"></option>
              <option value="warning" data-i18n="filterWarning"></option>
              <option value="error" data-i18n="filterError"></option>
            </select>
            <button class="btn btn--mini" onclick="PPX.logCopy()" data-i18n="copyLog"></button>
            <button class="btn btn--mini" onclick="PPX.logClear()" data-i18n="clearLog"></button>
          </div>
          <div class="term__body" id="log"></div>
          <div class="term__foot">
            <button class="btn btn--tiny" id="lockbtn" onclick="PPX.logUnlock()" hidden><span data-i18n="logUnlock"></span></button>
            <span class="mute" id="logcount"></span>
          </div>
        </div>
      </section>
    </div>
  </div>
</section>

<section class="step" id="step-2" hidden>
  <div class="grid grid--split">
    <div class="panel pair-root" id="pair-root">
      <div class="panel__head">
        <h2 style="font-size:clamp(15px,1.15vw,18px)" data-i18n="qrTitle"></h2>
        <span class="tag" id="pair-badge" data-i18n="loadingShort"></span>
      </div>
      <p class="panel__sub" data-i18n="qrSub"></p>
      <div id="pair-body"></div>
    </div>

    <div class="stack">
      <section class="panel">
        <div class="panel__head">
          <h3 data-i18n="devices"></h3>
          <span class="tag" id="devices-count">0</span>
        </div>
        <div id="devices"></div>
      </section>
      <section class="panel">
        <div class="panel__head"><h3 data-i18n="bridgeTitle"></h3><span class="tag" id="daemon-tag">—</span></div>
        <div class="grid grid--stats" id="bridge"></div>
        <p class="field__note mono" id="bridge-binary" style="margin-top:8px"></p>
        <p class="field__note mono" id="bridge-install" style="margin-top:6px"></p>
      </section>
    </div>
  </div>
</section>

<section class="step" id="step-3" hidden>
  <div class="panel">
    <div class="panel__head"><h2 data-i18n="s3Title"></h2><span class="tag" id="engines-badge">—</span></div>
    <p class="panel__sub" data-i18n="s3Desc"></p>
    <div class="engines" id="engines"></div>
  </div>

  <div class="grid grid--split" style="margin-top:12px">
    <div class="stack">
      <section class="panel">
        <div class="panel__head"><h3 data-i18n="meshTitle"></h3><span class="tag" id="mesh-tag">—</span></div>
        <div id="mesh"></div>
      </section>
      <section class="panel">
        <div class="panel__head"><h3 data-i18n="arkTitle"></h3><span class="tag" id="ark-tag">—</span></div>
        <div id="ark"></div>
      </section>
    </div>
    <div class="stack">
      <section class="panel">
        <div class="panel__head"><h3 data-i18n="sentinelTitle"></h3><span class="tag" id="sentinel-tag">—</span></div>
        <div id="sentinel"></div>
      </section>
      <section class="panel">
        <div class="panel__head"><h3 data-i18n="drillTitle"></h3></div>
        <div id="drill"></div>
      </section>
    </div>
  </div>

  <div class="savebar">
    <div class="savebar__state">
      <span class="savebar__text" id="save-text" data-i18n="saved"></span>
      <span class="savebar__rev mono" id="save-rev"></span>
    </div>
    <button class="btn" onclick="PPX.revert()" data-i18n="revert"></button>
    <button class="btn btn--primary" id="btn-save" onclick="PPX.save()" data-i18n="save"></button>
  </div>
</section>

<section class="step" id="step-4" hidden>
  <div class="panel">
    <div class="panel__head">
      <h2 data-i18n="s4Title"></h2>
      <span class="tag" id="pv-badge">—</span>
    </div>
    <p class="panel__sub" data-i18n="s4Desc"></p>
    <div class="grid grid--stats" id="pv-stats"></div>
    <hr class="hair">
    <p class="field__note" data-i18n="pvGuarantee"></p>
  </div>

  <div class="grid grid--split" style="margin-top:12px">
    <div class="stack">
      <section class="panel">
        <div class="panel__head">
          <h3 data-i18n="pvAccessTitle"></h3>
          <span class="tag" id="pv-auth-tag">—</span>
        </div>
        <div id="pv-access"></div>
        <hr class="hair">
        <div class="btn-row">
          <button class="btn btn--mini" id="pv-ask" onclick="PPX.pvAuthorize()">—</button>
          <button class="btn btn--mini" id="pv-check" onclick="PPX.pvCheck()" data-i18n="pvCheck"></button>
        </div>
        <div class="engine__meta" id="pv-check-out"></div>
        <p class="field__note" data-i18n="pvAuthNote"></p>
        <hr class="hair">
        <span class="field__label" data-i18n="pvDirsTitle"></span>
        <div id="pv-dirs"></div>
        <div class="btn-row" style="margin-top:8px">
          <button class="btn btn--mini" id="pv-adddir" onclick="PPX.pvAddDir()" data-i18n="pvDirAdd"></button>
        </div>
        <p class="field__note" data-i18n="pvDirHint"></p>
        <hr class="hair">
        <span class="field__label" data-i18n="pvDirsKnown"></span>
        <div class="list" id="pv-dirs-known"></div>
        <p class="field__note" data-i18n="pvDirsKnownNote"></p>
      </section>
      <section class="panel">
        <div class="panel__head"><h3 data-i18n="pvRulesTitle"></h3></div>
        <div id="pv-rules"></div>
      </section>
    </div>

    <div class="stack">
      <section class="panel">
        <div class="panel__head">
          <h3 data-i18n="pvPropTitle"></h3>
          <span class="tag" id="pv-prop-tag">0</span>
        </div>
        <div class="pv" id="pv-proposals"></div>
      </section>
      <section class="panel">
        <div class="panel__head">
          <h3 data-i18n="pvBookTitle"></h3>
          <span class="tag" id="pv-book-tag">0</span>
        </div>
        <div class="pv" id="pv-bookings"></div>
      </section>
      <section class="panel">
        <div class="panel__head">
          <h3 data-i18n="pvAuditTitle"></h3>
          <button class="btn btn--tiny" onclick="PPX.pvAuditCopy()" data-i18n="pvAuditCopy"></button>
        </div>
        <div class="pv-log" id="pv-audit"></div>
      </section>
    </div>
  </div>

  <div class="savebar">
    <div class="savebar__state">
      <span class="savebar__text" id="pv-save-text" data-i18n="saved"></span>
      <span class="savebar__rev mono" id="pv-save-rev"></span>
    </div>
    <button class="btn" onclick="PPX.revert()" data-i18n="revert"></button>
    <button class="btn btn--primary" id="pv-save" onclick="PPX.save()" data-i18n="save"></button>
  </div>
</section>

<section class="step" id="step-5" hidden>
  <div class="panel">
    <div class="panel__head">
      <h2 data-i18n="s5Title"></h2>
      <span class="tag" id="hv-badge">—</span>
    </div>
    <p class="panel__sub" data-i18n="s5Desc"></p>
    <div class="grid grid--stats" id="hv-stats"></div>
    <hr class="hair">
    <p class="field__note" data-i18n="hvGuarantee"></p>
  </div>

  <div class="grid grid--split" style="margin-top:12px">
    <div class="stack">
      <section class="panel">
        <div class="panel__head">
          <h3 data-i18n="hvDiscTitle"></h3>
          <span class="tag" id="hv-disc-tag">—</span>
        </div>
        <div class="pv" id="hv-caps"><div class="empty" data-i18n="hvDiscIdle"></div></div>
        <div class="btn-row" style="margin-top:8px">
          <button class="btn btn--mini" id="hv-scan" onclick="PPX.hvScan()" data-i18n="hvScan"></button>
        </div>
        <p class="field__note" id="hv-bound"></p>
      </section>
      <section class="panel">
        <div class="panel__head">
          <h3 data-i18n="hvPropTitle"></h3>
          <span class="tag" id="hv-prop-tag">0</span>
        </div>
        <div class="pv" id="hv-proposals"></div>
      </section>
    </div>

    <div class="stack">
      <section class="panel">
        <div class="panel__head"><h3 data-i18n="hvSwitchTitle"></h3></div>
        <div id="hv-switches"></div>
        <p class="field__note" data-i18n="hvSwitchNote"></p>
        <hr class="hair">
        <div class="fields" id="hv-fields"></div>
        <hr class="hair">
        <span class="field__label" data-i18n="hvEntitiesTitle"></span>
        <div id="hv-entities"></div>
        <div class="btn-row" style="margin-top:8px">
          <button class="btn btn--mini" id="hv-addentity" onclick="PPX.hvAddEntity()" data-i18n="hvEntityAdd"></button>
        </div>
        <p class="field__note" data-i18n="hvEntityNote"></p>
        <hr class="hair">
        <span class="field__label" data-i18n="hvTargetsTitle"></span>
        <div id="hv-targets"></div>
        <div class="btn-row" style="margin-top:8px">
          <button class="btn btn--tiny" id="hv-addtarget" onclick="PPX.hvAddTarget()" data-i18n="hvTargetAdd"></button>
        </div>
        <p class="field__note" data-i18n="hvTargetNote"></p>
      </section>
      <section class="panel">
        <div class="panel__head"><h3 data-i18n="hvStatusTitle"></h3></div>
        <div class="list" id="hv-status"><div class="empty" data-i18n="hvStatusIdle"></div></div>
        <div class="btn-row" style="margin-top:8px">
          <button class="btn btn--tiny" onclick="PPX.hvStatus()" data-i18n="hvRefresh"></button>
        </div>
        <p class="field__note" data-i18n="hvGateNote"></p>
      </section>
    </div>
  </div>

  <div class="grid grid--split" style="margin-top:12px">
    <div class="stack">
      <section class="panel">
        <div class="panel__head">
          <h3 data-i18n="upTitle"></h3>
          <span class="tag" id="up-badge">—</span>
        </div>
        <p class="panel__sub" data-i18n="upDesc"></p>
        <div class="grid grid--stats" id="up-stats"></div>
        <div class="pv" id="up-pending"></div>
        <div class="btn-row" style="margin-top:8px">
          <button class="btn btn--mini" id="up-check" onclick="PPX.upCheck()" data-i18n="upCheck"></button>
        </div>
        <p class="field__note" id="up-bound"></p>
      </section>
      <section class="panel">
        <div class="panel__head">
          <h3 data-i18n="dcFeedTitle"></h3>
          <span class="tag" id="dc-feed-tag">0</span>
        </div>
        <div class="grid grid--stats" id="dc-stats"></div>
        <div class="list" id="dc-list"><div class="empty" data-i18n="dcEmpty"></div></div>
        <div class="btn-row" style="margin-top:8px">
          <button class="btn btn--mini" id="dc-refresh" onclick="PPX.dcRefresh()" data-i18n="dcRefresh"></button>
        </div>
        <p class="field__note" data-i18n="dcRefreshNote"></p>
      </section>
    </div>

    <div class="stack">
      <section class="panel">
        <div class="panel__head"><h3 data-i18n="upConfigTitle"></h3></div>
        <div id="up-switch"></div>
        <p class="field__note" data-i18n="upSwitchNote"></p>
        <hr class="hair">
        <div class="fields" id="up-fields"></div>
        <p class="field__note" data-i18n="upGateNote"></p>
      </section>
      <section class="panel">
        <div class="panel__head">
          <h3 data-i18n="dcConfigTitle"></h3>
          <span class="tag" id="dc-badge">—</span>
        </div>
        <div id="dc-switch"></div>
        <p class="field__note" data-i18n="dcSwitchNote"></p>
        <hr class="hair">
        <div class="fields" id="dc-fields"></div>
        <hr class="hair">
        <span class="field__label" data-i18n="dcFoldersTitle"></span>
        <div id="dc-folders"></div>
        <div class="btn-row" style="margin-top:8px">
          <button class="btn btn--tiny" id="dc-folder-add" onclick="PPX.dcAddFolder()" data-i18n="dcFolderAdd"></button>
        </div>
        <p class="field__note" data-i18n="dcFolderNote"></p>
        <hr class="hair">
        <span class="field__label" data-i18n="dcFeedsTitle"></span>
        <div id="dc-feeds"></div>
        <div class="btn-row" style="margin-top:8px">
          <button class="btn btn--tiny" id="dc-feed-add" onclick="PPX.dcAddFeed()" data-i18n="dcFeedAdd"></button>
        </div>
        <p class="field__note" data-i18n="dcFeedNote"></p>
        <hr class="hair">
        <span class="field__label" data-i18n="dcMcpTitle"></span>
        <div id="dc-mcp"></div>
        <div class="btn-row" style="margin-top:8px">
          <button class="btn btn--tiny" id="dc-mcp-add" onclick="PPX.dcAddMcp()" data-i18n="dcMcpAdd"></button>
        </div>
        <p class="field__note" data-i18n="dcMcpNote"></p>
      </section>
      <section class="panel">
        <div class="panel__head">
          <h3 data-i18n="dcSourcesTitle"></h3>
          <span class="tag" id="dc-src-tag">0</span>
        </div>
        <div class="list" id="dc-sources"><div class="empty" data-i18n="dcSourcesIdle"></div></div>
        <p class="field__note" data-i18n="dcSourcesNote"></p>
      </section>
    </div>
  </div>

  <div class="grid grid--split" style="margin-top:12px">
    <div class="stack">
      <section class="panel">
        <div class="panel__head">
          <h3 data-i18n="geTitle"></h3>
          <span class="tag" id="ge-badge">—</span>
        </div>
        <p class="panel__sub" data-i18n="geDesc"></p>
        <div class="grid grid--stats" id="ge-stats"></div>
        <div class="btn-row" style="margin-top:8px">
          <button class="btn btn--mini" id="ge-start" onclick="PPX.geStart()" data-i18n="geStart"></button>
          <button class="btn btn--mini" id="ge-stop" onclick="PPX.geStop()" data-i18n="geStop"></button>
          <button class="btn btn--mini" id="ge-health" onclick="PPX.geHealth()" data-i18n="geHealth"></button>
        </div>
        <div class="pv" id="ge-state"></div>
        <p class="field__note" id="ge-bound"></p>
        <p class="field__note" id="ge-policy"></p>
        <p class="field__note" id="ge-licence"></p>
      </section>
      <section class="panel">
        <div class="panel__head">
          <h3 data-i18n="geMcpTitle"></h3>
          <span class="tag" id="ge-mcp-tag">—</span>
        </div>
        <div class="list" id="ge-tools"><div class="empty" data-i18n="geToolsIdle"></div></div>
        <div class="btn-row" style="margin-top:8px">
          <button class="btn btn--tiny" onclick="PPX.geControl('register')" data-i18n="geMcpRegister"></button>
          <button class="btn btn--tiny" onclick="PPX.geControl('syncTools')" data-i18n="geMcpSync"></button>
          <button class="btn btn--tiny" onclick="PPX.geControl('unregister')" data-i18n="geMcpUnregister"></button>
        </div>
        <p class="field__note" id="ge-mcp-note"></p>
      </section>
    </div>

    <div class="stack">
      <section class="panel">
        <div class="panel__head"><h3 data-i18n="geConfigTitle"></h3></div>
        <div id="ge-switch"></div>
        <p class="field__note" data-i18n="geSwitchNote"></p>
        <hr class="hair">
        <div class="fields" id="ge-fields"></div>
        <div class="btn-row" style="margin-top:8px">
          <button class="btn btn--tiny" onclick="PPX.geControl('verify')" data-i18n="geVerify"></button>
          <button class="btn btn--tiny" onclick="PPX.geControl('install')" data-i18n="geInstall"></button>
        </div>
        <p class="field__note" data-i18n="geInstallNote"></p>
        <hr class="hair">
        <span class="field__label" data-i18n="geCredTitle"></span>
        <div class="list" id="ge-creds"></div>
        <p class="field__note" data-i18n="geCredNote"></p>
      </section>
    </div>
  </div>

  <div class="panel" style="margin-top:12px">
    <div class="panel__head">
      <h3 data-i18n="asTitle"></h3>
      <span class="tag" id="as-badge">—</span>
    </div>
    <p class="panel__sub" data-i18n="asDesc"></p>
    <div class="grid grid--stats" id="as-stats"></div>
    <div class="grid grid--split" style="margin-top:12px">
      <div class="stack">
        <span class="field__label" data-i18n="asSwitchesTitle"></span>
        <div id="as-switches"></div>
        <p class="field__note" data-i18n="asSwitchNote"></p>
        <hr class="hair">
        <div class="fields" id="as-fields"></div>
        <div class="btn-row" style="margin-top:8px">
          <button class="btn btn--mini" onclick="PPX.asRun('briefingNow')" data-i18n="asBriefingNow"></button>
          <button class="btn btn--mini" onclick="PPX.asRun('patrolNow')" data-i18n="asPatrolNow"></button>
          <button class="btn btn--mini" onclick="PPX.asRun('refreshMail')" data-i18n="asMailNow"></button>
        </div>
        <p class="field__note" id="as-last-report"></p>
        <hr class="hair">
        <span class="field__label" data-i18n="asRepairsTitle"></span>
        <div id="as-repairs"></div>
        <div class="btn-row" style="margin-top:8px">
          <button class="btn btn--tiny" id="as-addrepair" onclick="PPX.asAddRepair()" data-i18n="asRepairAdd"></button>
        </div>
        <p class="field__note" data-i18n="asRepairsNote"></p>
      </div>
      <div class="stack">
        <span class="field__label" data-i18n="asConnectorsTitle"></span>
        <div class="list" id="as-connectors"></div>
        <p class="field__note" data-i18n="asConnectorsNote"></p>
        <hr class="hair">
        <span class="field__label" data-i18n="asMailCredsTitle"></span>
        <div id="as-creds"></div>
        <p class="field__note" data-i18n="asCredNote"></p>
      </div>
    </div>
    <hr class="hair">
    <div class="panel__head">
      <h3 data-i18n="asPendingTitle"></h3>
      <span class="tag" id="as-pending-tag">0</span>
    </div>
    <div class="pv" id="as-pending"></div>
    <div class="btn-row" style="margin-top:8px">
      <button class="btn btn--tiny" onclick="PPX.asRun('cancelPending')" data-i18n="asCancelAll"></button>
    </div>
    <p class="field__note" data-i18n="asPendingNote"></p>
    <hr class="hair">
    <div class="panel__head">
      <h3 data-i18n="asAuditTitle"></h3>
      <span class="tag" id="as-audit-tag">0</span>
    </div>
    <div class="list" id="as-audit"></div>
    <p class="field__note" id="as-boundary"></p>
  </div>

  <div class="savebar">
    <div class="savebar__state">
      <span class="savebar__text" id="hv-save-text" data-i18n="saved"></span>
      <span class="savebar__rev mono" id="hv-save-rev"></span>
    </div>
    <button class="btn" onclick="PPX.revert()" data-i18n="revert"></button>
    <button class="btn btn--primary" id="hv-save" onclick="PPX.save()" data-i18n="save"></button>
  </div>
</section>
</main>

<div class="drawer" id="drawer">
  <button class="drawer__head" onclick="PPX.devToggle()">
    <h3 data-i18n="devTitle"></h3>
    <span class="mute" data-i18n="devHint"></span>
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 5l7 7-7 7"/></svg>
  </button>
  <div class="drawer__body" id="dev-body" hidden>
    <div class="stack">
      <span class="field__label" data-i18n="pairDiagTitle"></span>
      <div class="stack" id="pair-diag"></div>
      <p class="field__note" data-i18n="pairDiagNote"></p>
    </div>
    <div class="stack">
      <div class="btn-row">
        <button class="btn btn--mini" onclick="PPX.fetchRaw()" data-i18n="rawFetch"></button>
        <button class="btn btn--mini" onclick="PPX.rawCopy()" data-i18n="rawCopy"></button>
      </div>
      <pre class="raw" id="raw">—</pre>
    </div>
    <div class="stack">
      <label class="field__label" for="cmd" data-i18n="cmdLabel"></label>
      <textarea id="cmd" spellcheck="false"></textarea>
      <p class="field__note" data-i18n="cmdHint"></p>
      <div class="btn-row">
        <button class="btn" onclick="PPX.cmdSend()" data-i18n="cmdSend"></button>
        <button class="btn btn--ghost" onclick="PPX.cmdClear()" data-i18n="cmdClear"></button>
      </div>
      <pre class="raw" id="cmdout">—</pre>
    </div>
  </div>
</div>

<div class="brandnote">
  <p class="brandnote__head">
    <span class="brandnote__pos" data-i18n="brandPosition"></span>
    <span class="brandnote__slogan" data-i18n="brandSlogan"></span>
  </p>
  <p class="brandnote__mission" data-i18n="brandMission"></p>
  <p class="brandnote__role" data-i18n="brandRole"></p>
</div>

<footer class="app__foot">
  <span class="mono" id="foot-ref"></span>
  <span class="mono" id="foot-uptime"></span>
  <span data-i18n="loopbackNote"></span>
</footer>

</div>
<div id="toasts" role="status" aria-live="polite"></div>

<script>
"use strict";
/* =====================================================================
   POPOPX Mac Node console — vanilla ES2020, no dependencies.

   Security rules that are enforced throughout this script:
   * Every value that comes from the node (snapshot fields, SSE frames,
     subprocess log lines, paths, device labels) is rendered with
     textContent or createElement. innerHTML is used exactly once, on a
     hard-coded, non-constant SVG path table. There is no string template
     that interpolates remote data into markup anywhere in this file.
   * All network calls go through api()/apiText(), which attach the
     X-PPX-Token header and throw APIError on non-2xx.
   ===================================================================== */

var TOKEN = (function () {
  var m = new URLSearchParams(window.location.search).get("t");
  return m ? String(m) : "";
})();

var ROUTE = {
  snapshot: "/api/snapshot",
  events: "/api/events",
  installStart: "/api/install/start",
  installCancel: "/api/install/cancel",
  pairingRotate: "/api/pairing/rotate",
  pairingQR: "/api/pairing/qr.png",
  pairingRevoke: "/api/pairing/revoke",
  settings: "/api/settings",
  engineToggle: "/api/engine/toggle",
  engineInvoke: "/api/engine/invoke",
  command: "/api/command",
  health: "/api/health",
  privacyAuthorize: "/api/privacy/authorize",
  privacyDecision: "/api/privacy/decision",
  // Console-only, like the two above it: writing a Keychain item is the setup act that
  // precedes an authorization, so no tool path and no phone command may reach it.
  hubCredential: "/api/hub/credential",
  // The console self-check calls the same tool route an assistant calls, so a green
  // line on the panel is evidence about the entry point, not about a special path.
  toolAvailability: "/v1/tools/calendar/availability",
  // Discovery: the card reads the cached snapshot with a GET, and only the button waits.
  discoveryCapabilities: "/v1/discovery/capabilities",
  discoveryScan: "/v1/discovery/scan",
  // The three bridge readouts, called through the same `/v1/tools/` surface a paired phone
  // uses. A panel that had its own status endpoint would be a second answer to
  // 「is this bridge up」, and the two would disagree about the switch.
  toolMCPStatus: "/v1/tools/mcp/status",
  toolHomeStatus: "/v1/tools/home/status",
  toolCalDavStatus: "/v1/tools/caldav/status",
  // Signed updates and Discover are console-only actions: the check fetches a
  // signed manifest, and the decision mints its receipt inside the node from
  // this call, so neither a tool path nor a phone command can reach them.
  updateCheck: "/api/update/check",
  updateDecision: "/api/update/decision",
  discoverRefresh: "/api/discover/refresh",
  // The local globe's two console-only paths: one control verb per click, and the
  // one-way credential save whose reply is a Keychain reference, never the value.
  godsEyeControl: "/api/godseye/control",
  godsEyeCredential: "/api/godseye/credential",
  // The private assistant's three console-only paths: one control verb per click,
  // an approval whose receipt is minted inside the node, and the one-way mail
  // credential save whose reply is a Keychain reference rather than the value.
  assistantControl: "/api/assistant/control",
  assistantDecision: "/api/assistant/decision",
  assistantMailCredential: "/api/assistant/mail/credential"
};

var LEVEL_GLYPH = { debug: "·", info: "›", notice: "•", success: "✓", warning: "!", error: "✕" };
/* Short weekday glyphs are the same characters in both Chinese scripts, so the
   Traditional catalog of this one table is the Simplified table. */
var CJK_WEEKDAYS = ["日", "一", "二", "三", "四", "五", "六"];
var WEEKDAYS = { zh: CJK_WEEKDAYS, zhHant: CJK_WEEKDAYS, en: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"] };
var WEEKDAY_ORDER = [1, 2, 3, 4, 5, 6, 0];
var LOG_LIMIT = 900;
/* The two ceilings the hub panel enforces while typing. They are the node's numbers, and
   `HubBridgeTests` pins each one against `HubConfig` — the server truncates silently through
   `normalised`, so an untested copy here would be a page that lets an owner add rows the
   node then drops without saying so. */
var HV_ENTITY_LIMIT = 64;
var HV_TARGET_LIMIT = 8;

/* ---------------------------------------------------------------- i18n */
var I18N = {
  brandSub: { zh: "本地算力与物理执行中枢 · 仅回环可达", en: "Local compute and physical execution hub · loopback only" },
  /* The four brand layers of the platform, in the order the brand book reads:
     claim, slogan, positioning, mission. They are one wording across the menu
     bar, this page and both READMEs, and `MacNodeContractTests` compares the
     three surfaces so a rename cannot land in one of them. */
  brandClaim: { zh: "Connect Everything. 连接一切，让智能自由协作。", en: "Connect Everything." },
  brandSlogan: { zh: "自由连接 · 私密沟通 · 智能协作", en: "Connect Freely · Communicate Privately · Collaborate Intelligently" },
  brandPosition: { zh: "隐私优先的智能连接平台", en: "Privacy-First Intelligent Connection Platform" },
  brandRole: { zh: "POPOPX 隐私优先智能连接平台的本机边缘算力与隐私执行节点", en: "The on-device edge compute and privacy execution node of POPOPX, the Privacy-First Intelligent Connection Platform" },
  brandMission: { zh: "POPOPX 不只是提供连接工具，而是建立一个让人、AI、Agent、设备和服务能够安全连接、自由协作的开放生态。", en: "POPOPX does not merely provide connection tools — it builds an open ecosystem where people, AI, agents, devices, and services connect securely and collaborate freely." },
  loadingShort: { zh: "载入中", en: "Loading" },
  connecting: { zh: "连接中", en: "Connecting" },
  live: { zh: "已连接", en: "Connected" },
  retryState: { zh: "重连中", en: "Reconnecting" },
  offline: { zh: "已离线", en: "Offline" },
  offlineBanner: { zh: "控制台与节点的实时通道已中断，页面显示的是最后一次成功读取的数据。", en: "The live channel to the node dropped. This page shows the last snapshot that was read successfully." },
  retry: { zh: "立即重连", en: "Reconnect now" },
  /* The picker writes one node-wide setting, so these strings talk about both
     halves: what the page paints and what the node stores. */
  langGroup: { zh: "控制台语言", en: "Console language" },
  langFallback: { zh: "该语言尚未校对，页面暂以英文显示（简报与脚本仍按该语言生成）", en: "No proof-read catalog yet, so the page stays in English (briefings and scripts still use the chosen language)" },
  langSaveHint: { zh: "页面已切换；节点里的语言会在你点“保存”后更新", en: "The page switched; the node keeps its own language until you press Save" },
  langSaveFailed: { zh: "写入语言设置失败，已回到节点当前语言", en: "Could not store the language setting; back to the language the node uses" },
  railAria: { zh: "设置步骤", en: "Setup steps" },
  s1: { zh: "硬件与引擎部署", en: "Hardware & deploy" },
  s2: { zh: "iPhone 扫码配对", en: "iPhone pairing" },
  s3: { zh: "业务开关与物理权限", en: "Engines & physical authority" },
  s1Title: { zh: "第 1 步 · 硬件扫描与环境一键安装", en: "Step 1 · Hardware scan and one-click install" },
  s1Desc: { zh: "读取 Apple Silicon 画像，按统一内存档位推荐模型栈，并可一键把本地 AI 引擎装到这台 Mac。", en: "Reads the Apple Silicon profile, picks the model stack from unified memory, and installs the local AI engines on this Mac." },
  s2Title: { zh: "第 2 步 · iOS 扫码配对绑定", en: "Step 2 · Pair the iPhone" },
  s3Title: { zh: "第 3 步 · 10 大业务开关与物理权限", en: "Step 3 · Ten engines and physical authority" },
  s3Desc: { zh: "开关、空闲算力、物理哨兵与时光方舟的写入面板；所有改动都要显式保存到 config/settings.json。", en: "Switches, idle compute sharing, the physical sentinel and the chrono ark. Every change is written to config/settings.json explicitly." },
  loading: { zh: "等待节点快照…", en: "Waiting for the first snapshot…" },
  loadFailed: { zh: "无法读取节点状态", en: "Could not read node state" },
  reloadRetry: { zh: "重试", en: "Retry" },
  noData: { zh: "暂无数据", en: "No data yet" },
  chip: { zh: "芯片", en: "Chip" },
  cores: { zh: "CPU 核心", en: "CPU cores" },
  coresNote: { zh: "性能核 P · 能效核 E", en: "performance P · efficiency E" },
  mem: { zh: "统一内存", en: "Unified memory" },
  memNote: { zh: "Apple Silicon 共享池", en: "Shared Apple Silicon pool" },
  freeDisk: { zh: "可用 SSD", en: "Free SSD" },
  freeDiskNote: { zh: "总容量", en: "of total" },
  tier: { zh: "算力档位", en: "Compute tier" },
  loadTitle: { zh: "实时负载", en: "Live load" },
  loadNote: { zh: "采样于", en: "sampled" },
  memUsed: { zh: "已用内存", en: "Memory in use" },
  pressure: { zh: "内存压力", en: "Memory pressure" },
  processes: { zh: "活动进程", en: "Processes" },
  cpu: { zh: "CPU 负载", en: "CPU load" },
  nominal: { zh: "正常", en: "Nominal" },
  warning: { zh: "警告", en: "Warning" },
  critical: { zh: "危险", en: "Critical" },
  memTitle: { zh: "统一内存仪表盘", en: "Unified memory gauge" },
  usedOf: { zh: "已用", en: "used of" },
  toolchainTitle: { zh: "工具链探针", en: "Toolchain probes" },
  toolchainEmpty: { zh: "节点还没有回报任何工具链探测结果。", en: "The node has not reported any toolchain probe yet." },
  present: { zh: "已安装", en: "present" },
  missing: { zh: "缺失", en: "missing" },
  stepsTitle: { zh: "部署清单", en: "Provisioning checklist" },
  stepsEmpty: { zh: "尚无部署任务，点击左侧“一键自动部署”即可开始。", en: "No deploy run yet. Press one-click deploy to start." },
  logTitle: { zh: "实时安装日志", en: "Live install log" },
  levelFilter: { zh: "日志级别过滤", en: "Log level filter" },
  filterAll: { zh: "全部级别", en: "All levels" },
  filterInfo: { zh: "info 以上", en: "info and up" },
  filterNotice: { zh: "notice 以上", en: "notice and up" },
  filterWarning: { zh: "warning 以上", en: "warning and up" },
  filterError: { zh: "仅 error", en: "error only" },
  copyLog: { zh: "复制日志", en: "Copy log" },
  clearLog: { zh: "清屏", en: "Clear" },
  logCleared: { zh: "已清空显示（节点侧日志仍保留）", en: "View cleared (node-side log kept)" },
  logLines: { zh: "行日志", en: "log lines" },
  logLocked: { zh: "已暂停自动滚动", en: "Autoscroll paused" },
  logUnlock: { zh: "恢复自动滚动", en: "Resume autoscroll" },
  logEmpty: { zh: "日志窗口为空。安装开始时这里会实时滚动。", en: "The log window is empty. It starts streaming as soon as a deploy runs." },
  logCopied: { zh: "日志已复制", en: "Log copied" },
  deploy: { zh: "一键自动部署本地 AI 引擎", en: "One-click deploy local AI engines" },
  cancelInstall: { zh: "取消部署", en: "Cancel deploy" },
  idleHint: { zh: "会依次探测 brew / ffmpeg / uv / Ollama，按内存档位拉取适配权重，并初始化 LTX-2.5 工作区。", en: "Probes brew / ffmpeg / uv / Ollama, pulls the weights that fit the memory tier and prepares the LTX-2.5 workspace." },
  installing: { zh: "部署进行中", en: "Deploy running" },
  phaseIdle: { zh: "待部署", en: "Idle" },
  phaseDetecting: { zh: "探测环境", en: "Detecting" },
  phaseProvisioning: { zh: "安装依赖", en: "Provisioning" },
  phasePullingLLM: { zh: "拉取语言模型", en: "Pulling LLM" },
  phasePreparingWorkspace: { zh: "初始化工作区", en: "Preparing workspace" },
  phaseDownloadingWeights: { zh: "下载视频权重", en: "Downloading weights" },
  phaseVerifying: { zh: "校验", en: "Verifying" },
  phaseReady: { zh: "引擎就绪", en: "Engines ready" },
  phaseFailed: { zh: "部署失败", en: "Deploy failed" },
  phaseCancelled: { zh: "已取消", en: "Cancelled" },
  deployStarted: { zh: "已提交部署请求", en: "Deploy requested" },
  deployFailed: { zh: "无法启动部署", en: "Could not start the deploy" },
  deployCancel: { zh: "已请求取消", en: "Cancellation requested" },
  deployCancelFailed: { zh: "取消失败", en: "Cancellation failed" },
  installDone: { zh: "本地引擎已就绪", en: "Local engines are ready" },
  installFailedWhy: { zh: "上次部署失败", en: "Last deploy failed" },
  planTitle: { zh: "模型推荐阶梯", en: "Recommended model ladder" },
  planNote: { zh: "方案依据", en: "Plan rationale" },
  thBand: { zh: "内存档", en: "Memory band" },
  thLLM: { zh: "语言模型", en: "Language model" },
  thVideo: { zh: "视频精度", en: "Video precision" },
  thResident: { zh: "常驻内存", en: "Resident" },
  thNote: { zh: "策略", en: "Policy" },
  tierCap: { zh: "本机满血", en: "Full-precision local" },
  tierQuant: { zh: "本机量化", en: "Quantised local" },
  tierLight: { zh: "轻量本机", en: "Light local" },
  heavyLocal: { zh: "重型视频本机渲染", en: "Heavy video renders locally" },
  heavyMesh: { zh: "重型视频转边缘算力", en: "Heavy video routed to mesh" },
  noPlan: { zh: "节点尚未给出模型方案。", en: "The node has not produced a model plan yet." },
  modelTitle: { zh: "模型管理", en: "Model management" },
  modelDefault: { zh: "默认 · 按内存档位", en: "Default · by memory tier" },
  modelResident: { zh: "常驻估算", en: "Estimated resident" },
  modelAdmission: { zh: "内存准入", en: "Memory admission" },
  modelGguf: { zh: "自定义 GGUF", en: "Custom GGUF" },
  modelCopyPull: { zh: "复制拉取命令", en: "Copy pull command" },
  modelSwapWarn: { zh: "本机内存低于阈值，预计触发内存交换；节点已拒绝本机重载任务，避免 OOM 卡死。", en: "This Mac is at or under the swap line: heavy local jobs are refused rather than risk an OOM hang." },
  modelSwitched: { zh: "本地模型已切换", en: "Local model switched" },
  modelSwitchFailed: { zh: "模型切换失败", en: "Could not switch the local model" },
  modelUnpinned: { zh: "已回到内存档位默认", en: "Back to the hardware tier" },
  modelPinnedNote: { zh: "已固定，不再随内存档位变化", en: "Pinned — it no longer follows the memory tier" },
  modelUnknown: { zh: "该模型不在目录内，内存数字仍是本档位的估算值。", en: "This model is not in the catalog, so the memory figures are still the tier's own estimate." },
  qrTitle: { zh: "配对二维码", en: "Pairing QR" },
  qrSub: { zh: "iOS 端「发现 → Mac Node 配对」扫一扫；同一网络内即可建立端到端加密隧道。", en: "Scan it from iOS · Discover → Mac Node pairing. The encrypted tunnel comes up on the same network." },
  qr: { zh: "二维码", en: "QR code" },
  qrRetry: { zh: "重新载入二维码", en: "Reload the QR" },
  qrLoading: { zh: "正在渲染二维码…", en: "Rendering the QR…" },
  qrLoadFailed: { zh: "二维码图片读取失败", en: "Could not load the QR image" },
  noQR: { zh: "节点暂时无法输出二维码图片；下方加密链接仍然有效，可在 iOS 端手动粘贴。", en: "The node cannot render the QR image right now; the encrypted link below is still valid and can be pasted manually in iOS." },
  code: { zh: "端到端加密配对码", en: "End-to-end encrypted pairing code" },
  copyCode: { zh: "复制配对码", en: "Copy code" },
  uri: { zh: "/*PPX_SCHEME*/ 邀请链接", en: "/*PPX_SCHEME*/ invitation URI" },
  copyURI: { zh: "复制邀请链接", en: "Copy URI" },
  pairLink: { zh: "加密配对链接", en: "Encrypted pairing link" },
  copyLink: { zh: "复制配对链接", en: "Copy link" },
  pairLinkNote: { zh: "链接按全生态统一的邀请封装加密，不含信令节点域名；扫码内容与复制内容完全一致。", en: "The link is sealed with the ecosystem invite format, so it names no signalling node; the QR holds the very same bytes." },
  pairDiagTitle: { zh: "原始配对凭据（仅本机可见）", en: "Raw pairing credentials (this Mac only)" },
  pairDiagNote: { zh: "以下配对码与邀请链接包含 SMP 队列地址，仅供排障；对外分享请使用上方加密链接。", en: "The code and invitation URI below carry the SMP queue address and are for troubleshooting; share the encrypted link above." },
  pairDiagEmpty: { zh: "当前没有配对凭据；重新生成后这里会显示原始值。", en: "No pairing credential yet; rotate an offer and the raw values appear here." },
  pubkey: { zh: "节点公钥", en: "Node public key" },
  expiry: { zh: "有效期至", en: "Valid for" },
  expired: { zh: "此配对码已过期", en: "This pairing code has expired" },
  used: { zh: "此配对码已被使用", en: "This pairing code has been used" },
  oneTime: { zh: "一次性", en: "single use" },
  rotate: { zh: "重新生成", en: "Regenerate" },
  rotateFailed: { zh: "无法重新生成配对码", en: "Could not rotate the pairing offer" },
  noPairing: { zh: "信令网关尚未签发配对码。安装完成或守护进程启动后会自动出现。", en: "The signalling gateway has not minted an offer yet. It appears once the daemon is up." },
  tunnel: { zh: "已成功与 iPhone 建立加密隧道", en: "Encrypted tunnel with the iPhone is up" },
  tunnelSub: { zh: "该设备的公钥已加入白名单，只有它能驱动这台 Mac 的 10 大业务。", en: "This device key is whitelisted; only it can drive the ten engines on this Mac." },
  devices: { zh: "已配对设备", en: "Paired devices" },
  devicesEmpty: { zh: "还没有设备完成扫码配对。", en: "No device has completed the QR handshake yet." },
  revoke: { zh: "撤销", en: "Revoke" },
  revokeDone: { zh: "设备已撤销", en: "Device revoked" },
  revokeFailed: { zh: "撤销失败", en: "Revoke failed" },
  revokedRow: { zh: "已撤销", en: "revoked" },
  deviceModel: { zh: "机型", en: "Model" },
  pairedAt: { zh: "配对时间", en: "Paired" },
  lastSeen: { zh: "最后在线", en: "Last seen" },
  neverSeen: { zh: "尚未通信", en: "never seen" },
  copyPubkey: { zh: "复制公钥", en: "Copy key" },
  bridgeTitle: { zh: "SMP 信令网关", en: "SMP signalling bridge" },
  daemonStopped: { zh: "守护进程已停止", en: "Daemon stopped" },
  daemonStarting: { zh: "守护进程启动中", en: "Daemon starting" },
  daemonRunning: { zh: "守护进程运行中", en: "Daemon running" },
  daemonDegraded: { zh: "守护进程降级", en: "Daemon degraded" },
  daemonMissing: { zh: "缺少 popopx-chat 可执行文件", en: "popopx-chat binary missing" },
  accepted: { zh: "已接受指令", en: "Accepted" },
  rejected: { zh: "已拒绝指令", en: "Rejected" },
  delivered: { zh: "已回传结果", en: "Delivered" },
  outbox: { zh: "出站队列深度", en: "Outbox depth" },
  uptime: { zh: "运行时长", en: "Uptime" },
  wsOn: { zh: "WebSocket 已连", en: "WebSocket up" },
  wsOff: { zh: "WebSocket 未连", en: "WebSocket down" },
  daemonPath: { zh: "守护进程路径", en: "Daemon path" },
  bridgeErr: { zh: "最近错误", en: "Last error" },
  daemonInstall: { zh: "未安装 popopx-chat —— 先下载并校验再执行：curl -o- https://raw.githubusercontent.com/popopx-chat/popopx-chat/master/install.sh > popopx-install.sh；shasum -a 256 popopx-install.sh（摘要须与 README 安装说明里那条一致，不符就不要运行）；bash popopx-install.sh 会把可执行文件装进 ~/.local/bin/popopx-chat", en: "popopx-chat is not installed —— download it, check it, then run it: curl -o- https://raw.githubusercontent.com/popopx-chat/popopx-chat/master/install.sh > popopx-install.sh; shasum -a 256 popopx-install.sh (the digest must equal the one in the README install section — if it does not, do not run the script); bash popopx-install.sh installs the executable as ~/.local/bin/popopx-chat" },
  enginesTitle: { zh: "10 大业务引擎", en: "Ten business engines" },
  enginesBadge: { zh: "已启用", en: "enabled" },
  enginesLoading: { zh: "等待引擎描述符…", en: "Waiting for engine descriptors…" },
  runs: { zh: "执行", en: "runs" },
  failures: { zh: "失败", en: "failures" },
  artifacts: { zh: "产物", en: "artifacts" },
  lastRun: { zh: "上次", en: "last" },
  busyNow: { zh: "执行中", en: "busy" },
  idleNow: { zh: "空闲", en: "idle" },
  requires: { zh: "依赖", en: "needs" },
  needsModels: { zh: "需要本地模型", en: "needs local models" },
  deterministicFlag: { zh: "确定性 · 不经模型", en: "deterministic · no model" },
  toggleOn: { zh: "已开启", en: "Switched on" },
  toggleOff: { zh: "已关闭", en: "Switched off" },
  toggleFailed: { zh: "开关请求失败", en: "Switch request failed" },
  save: { zh: "保存配置", en: "Save settings" },
  saving: { zh: "保存中…", en: "Saving…" },
  saved: { zh: "配置与节点一致", en: "Settings match the node" },
  dirty: { zh: "有未保存的本地修改", en: "Local edits not saved" },
  saveDone: { zh: "配置已写入", en: "Settings written" },
  saveFailed: { zh: "保存失败", en: "Save failed" },
  conflict: { zh: "节点已有更新的配置版本，已用节点数据重置表单", en: "The node holds a newer revision; the form was reloaded from it" },
  revision: { zh: "配置版本", en: "revision" },
  revert: { zh: "放弃修改", en: "Discard" },
  reverted: { zh: "已恢复到节点配置", en: "Reverted to the node document" },
  meshTitle: { zh: "空闲算力共享", en: "Idle compute sharing" },
  meshOn: { zh: "共享开启", en: "sharing on" },
  meshOff: { zh: "共享关闭", en: "sharing off" },
  shareEnable: { zh: "允许出借空闲算力", en: "Lend idle cycles" },
  maxMem: { zh: "最大内存", en: "Max memory" },
  maxMemHint: { zh: "本机安全上限", en: "safe ceiling on this machine" },
  maxJobs: { zh: "并发任务", en: "Concurrent jobs" },
  minFree: { zh: "最低剩余磁盘 GB", en: "Min free disk GB" },
  ownerPresent: { zh: "仅机主在场时接单", en: "Only while the owner is present" },
  windows: { zh: "闲置接单时段", en: "Idle windows" },
  windowAdd: { zh: "新增时段", en: "Add window" },
  windowRemove: { zh: "删除", en: "Remove" },
  windowEmpty: { zh: "没有时段将永不接单；至少保留一个。", en: "With no window the node never accepts work." },
  from: { zh: "开始", en: "From" },
  to: { zh: "结束", en: "To" },
  weekdayShort: { zh: "星期", en: "Days" },
  acceptingNow: { zh: "当前正在接单", en: "Accepting now" },
  notAcceptingNow: { zh: "当前不接单", en: "Not accepting now" },
  accrued: { zh: "累计算力点", en: "Accrued points" },
  settled: { zh: "已结算任务", en: "Settled jobs" },
  activeJobs: { zh: "进行中任务", en: "Active jobs" },
  nextWindow: { zh: "下一个时段", en: "Next window" },
  meshSandbox: { zh: "沙箱占用", en: "Sandbox bytes" },
  sentinelTitle: { zh: "物理空间哨兵", en: "Physical-space sentinel" },
  sentinelSub: { zh: "确定性闭锁：不经大模型，收到 🔒 / LOCK_ALL 立即执行。", en: "Deterministic lockdown: no model in the loop, fires on 🔒 / LOCK_ALL instantly." },
  sentinelOn: { zh: "哨兵已启用", en: "Sentinel armed" },
  sentinelOff: { zh: "哨兵已停用", en: "Sentinel off" },
  mounts: { zh: "需卸载的挂载卷 / NAS 路径", en: "Volumes to unmount" },
  mountAdd: { zh: "新增挂载路径", en: "Add path" },
  mountEmpty: { zh: "没有配置挂载路径；闭锁时只清剪贴板、锁屏与 Webhook。", en: "No mount paths configured; lockdown will only clear the clipboard, lock the screen and hit the webhook." },
  mountHint: { zh: "例如 /Volumes/ENCRYPTED 或 smb://… （闭锁时执行 diskutil unmount）", en: "e.g. /Volumes/ENCRYPTED or smb://… (unmounted via diskutil at lock time)" },
  clipboard: { zh: "闭锁时清空剪贴板", en: "Clear clipboard on lock" },
  lockScreen: { zh: "锁定屏幕", en: "Lock the screen" },
  sleepDisplays: { zh: "关闭显示器", en: "Sleep displays" },
  phrases: { zh: "触发词（逗号分隔）", en: "Trigger phrases (comma separated)" },
  hookUrl: { zh: "Home Assistant / Webhook URL", en: "Home Assistant / webhook URL" },
  hookSecret: { zh: "Webhook 签名密钥", en: "Webhook signing secret" },
  secretShow: { zh: "显示", en: "Show" },
  secretHide: { zh: "隐藏", en: "Hide" },
  drill: { zh: "立即演练", en: "Run drill now" },
  drillDone: { zh: "演练回执已返回", en: "Drill receipt returned" },
  drillFailed: { zh: "演练失败", en: "Drill failed" },
  drillPending: { zh: "演练执行中…", en: "Drill running…" },
  drillTitle: { zh: "确定性闭锁回执", en: "Deterministic lockdown receipts" },
  receiptEmpty: { zh: "尚无闭锁记录。点“立即演练”会产生一条真实回执。", en: "No lockdown on record yet. Press run-drill-now to produce one." },
  modelFree: { zh: "零模型参与", en: "zero-model" },
  modelUsed: { zh: "有模型参与（异常）", en: "model involved (unexpected)" },
  receiptTrigger: { zh: "触发词", en: "Trigger" },
  receiptClip: { zh: "剪贴板", en: "Clipboard" },
  receiptUnmount: { zh: "已卸载", en: "Unmounted" },
  receiptMountFail: { zh: "卸载失败", en: "Mount failures" },
  receiptScreen: { zh: "锁屏", en: "Screen" },
  receiptWebhook: { zh: "Webhook", en: "Webhook" },
  receiptElapsed: { zh: "耗时", en: "Elapsed" },
  arkTitle: { zh: "时光数字方舟", en: "Chrono Ark" },
  arkSub: { zh: "密码学时间锁 + 心跳失联守护，到期或失联后按托付解封。", en: "Cryptographic time lock plus missed-beat guardianship; opens on schedule or after silence." },
  arkOk: { zh: "守护正常", en: "Guardian healthy" },
  arkAlert: { zh: "心跳已逾期", en: "Heartbeat overdue" },
  beat: { zh: "心跳周期（小时）", en: "Heartbeat interval (hours)" },
  missed: { zh: "容忍失联次数", en: "Missed beats tolerated" },
  graceDue: { zh: "失联判定时刻", en: "Release deadline" },
  lockDur: { zh: "时间锁时长（秒）", en: "Time-lock (seconds)" },
  lockDays: { zh: "约合", en: "about" },
  daysUnit: { zh: "天", en: "days" },
  unlocks: { zh: "最早可解封", en: "earliest unlock" },
  directory: { zh: "加密档案目录", en: "Encrypted archive directory" },
  dirHint: { zh: "由节点固定在 vault/sealed/，正是 chrono_ark 写入胶囊的位置", en: "Fixed by the node at vault/sealed/, which is exactly where chrono_ark writes capsules" },
  dirReveal: { zh: "在访达中打开", en: "Reveal in Finder" },
  dirUnsupported: { zh: "网页不能列出本机目录，也不能改这个路径；“在访达中打开”由本机节点执行。", en: "A page cannot list local directories or change this path; “Reveal in Finder” is executed by the node on this machine." },
  revealFailed: { zh: "无法让节点打开档案目录", en: "The node could not open the archive folder" },
  archives: { zh: "已封存档案", en: "Sealed archives" },
  archivesEmpty: { zh: "还没有封存任何档案。", en: "Nothing has been sealed yet." },
  archiveSealedAt: { zh: "封存于", en: "sealed" },
  archiveOpens: { zh: "可解封于", en: "opens" },
  archiveRounds: { zh: "派生轮次", en: "rounds" },
  archiveFingerprint: { zh: "密钥指纹", en: "key fingerprint" },
  archiveOpen: { zh: "已到期待投递", en: "past lock" },
  archiveSealed: { zh: "仍在锁定", en: "still sealed" },
  beneficiary: { zh: "继承人称呼", en: "Beneficiary name" },
  beneficiaryQueue: { zh: "继承人队列地址", en: "Beneficiary queue" },
  devTitle: { zh: "开发者抽屉", en: "Developer drawer" },
  devHint: { zh: "原始快照 JSON 与信令指令注入", en: "Raw snapshot JSON and wire command injection" },
  devOpen: { zh: "展开", en: "Expand" },
  devClose: { zh: "收起", en: "Collapse" },
  rawFetch: { zh: "抓取原始快照", en: "Fetch raw snapshot" },
  rawCopy: { zh: "复制 JSON", en: "Copy JSON" },
  rawEmpty: { zh: "尚未抓取。", en: "Not fetched yet." },
  rawFailed: { zh: "抓取失败", en: "Fetch failed" },
  rawTruncated: { zh: "内容过长，已截断显示", en: "Truncated for display" },
  cmdLabel: { zh: "注入 ::popopx_sys::NODE_CMD 指令", en: "Inject a ::popopx_sys::NODE_CMD command" },
  cmdHint: { zh: "格式 ::popopx_sys::NODE_CMD::{serviceId}::{action}::{payload}，走与 iOS 完全相同的执行路径。", en: "Format ::popopx_sys::NODE_CMD::{serviceId}::{action}::{payload}; it takes the exact path an iOS command takes." },
  cmdSend: { zh: "执行", en: "Execute" },
  cmdClear: { zh: "清空输出", en: "Clear output" },
  cmdEmpty: { zh: "请输入指令文本", en: "Type a command first" },
  cmdDone: { zh: "指令已执行", en: "Command executed" },
  cmdFailed: { zh: "指令执行失败", en: "Command failed" },
  copyDone: { zh: "已复制到剪贴板", en: "Copied to the clipboard" },
  copyFailed: { zh: "复制失败", en: "Copy failed" },
  loopbackNote: { zh: "页面与 API 全部来自本机 127.0.0.1；无外部脚本、无字体、无追踪。", en: "Page and API come from 127.0.0.1 only; no external scripts, fonts or trackers." },
  unknown: { zh: "未知", en: "unknown" },
  yes: { zh: "是", en: "yes" },
  no: { zh: "否", en: "no" },
  never: { zh: "从未", en: "never" },
  secondsUnit: { zh: "秒", en: "s" },
  ago: { zh: "前", en: "ago" },
  paired: { zh: "已配对", en: "Paired" },
  released: { zh: "已开启", en: "Released" },
  now: { zh: "现在", en: "now" },
  /* Step four — the privacy bridges. The copy states what the node actually does,
     not what a bridge could promise: a switch here authorizes a local read, and a
     write still needs the second click below. */
  s4: { zh: "隐私桥接", en: "Privacy bridges" },
  s4Title: { zh: "隐私桥接与人工确认", en: "Privacy bridges and manual confirmation" },
  s4Desc: { zh: "日历与工作区的原始数据只在本机读取；这里列出的是节点生成的摘要与待确认动作。", en: "Raw calendar and workspace data is read on this Mac only; what is listed here is the node's own digest and the actions awaiting you." },
  pvGuarantee: { zh: "本页全部来自 127.0.0.1 的快照：日程标题、地点、参会人与文件正文在进入快照前已被丢弃；任何写入都要在这里或配对手机上再确认一次。", en: "Everything on this page comes from the loopback snapshot: event titles, locations, attendees and file bodies are discarded before it is encoded, and every write takes a second confirmation here or on a paired phone." },
  pvAccessTitle: { zh: "授权开关", en: "Authorization switches" },
  pvAuthNote: { zh: "开关是节点这一侧的授权；macOS 仍可能单独拒绝日历访问，下面显示系统的实际状态。", en: "A switch is the node's own grant; macOS can still refuse calendar access separately, so the system state is shown below." },
  pvCalSwitch: { zh: "读取日历空闲时段（不读取日程内容）", en: "Read calendar free/busy slots (not event content)" },
  pvReadSwitch: { zh: "读取已授权目录的文件摘要", en: "Summarize files inside authorized directories" },
  pvWriteSwitch: { zh: "在已授权目录内写入（每次需确认）", en: "Write inside authorized directories (each one confirmed)" },
  pvNotifySwitch: { zh: "有新提案时发送系统通知", en: "Notify me in Notification Center when a proposal arrives" },
  pvAskAccess: { zh: "请求日历权限", en: "Ask macOS for calendar access" },
  pvAuthAgain: { zh: "再次请求日历权限", en: "Ask macOS again" },
  pvAuthAsked: { zh: "已按系统答复更新授权状态", en: "Authorization state updated from macOS" },
  pvAuthAskFailed: { zh: "请求授权失败", en: "The access request failed" },
  pvCheck: { zh: "自检未来 7 天", en: "Self-check the next 7 days" },
  pvCheckOff: { zh: "日历桥接未开启，自检不会发起查询", en: "The calendar bridge is off, so no query is sent" },
  pvCheckFree: { zh: "找到空闲时段", en: "Free slots found" },
  pvCheckNone: { zh: "这 7 天没有可用空闲时段", en: "No free slot inside this window" },
  pvCheckFailed: { zh: "自检被拒", en: "Self-check refused" },
  pvDirsTitle: { zh: "已授权目录", en: "Authorized directories" },
  pvDirAdd: { zh: "新增目录", en: "Add directory" },
  pvDirRemove: { zh: "移除", en: "Remove" },
  pvDirHint: { zh: "用 ~ 开头的写法即可，例如 ~/Documents/项目。节点只接受前三个，且只会读取目录内的文件。", en: "Write them user-style, for example ~/Documents/Projects. The node keeps the first three and only reads inside them." },
  pvDirEmpty: { zh: "还没有目录；摘要与写入都会被拒绝。", en: "No directory yet; summarization and writes are both refused." },
  pvDirMax: { zh: "已达到目录上限，先移除一个", en: "Directory ceiling reached, remove one first" },
  pvDirOpen: { zh: "存在且可读", en: "Present and reachable" },
  pvDirClosed: { zh: "不存在或不可达", en: "Missing or unreachable" },
  pvDirsKnown: { zh: "节点实际接受并解析的目录", en: "Directories the node actually accepts and resolves" },
  pvDirsKnownNote: { zh: "这一列来自节点，不是输入框：保存后才会一致，被裁掉的条目说明超过了上限。", en: "This column is the node's answer, not the input boxes: it only matches after a save, and a dropped entry means the ceiling was passed." },
  pvDirNoneSaved: { zh: "节点没有接受任何目录", en: "The node has accepted no directory" },
  pvRulesTitle: { zh: "空闲判定与提案默认值", en: "Free-slot rules and proposal defaults" },
  pvWorkStart: { zh: "工作开始", en: "Working start" },
  pvWorkEnd: { zh: "工作结束", en: "Working end" },
  pvDuration: { zh: "默认时长（分钟）", en: "Default length (min)" },
  pvBuffer: { zh: "前后缓冲（分钟）", en: "Buffer around (min)" },
  pvLunchStart: { zh: "午休开始", en: "Lunch start" },
  pvLunchEnd: { zh: "午休结束", en: "Lunch end" },
  pvBlockLunch: { zh: "把午休视为占用", en: "Treat lunch as busy" },
  pvWorkdays: { zh: "工作日", en: "Workdays" },
  pvZone: { zh: "时区", en: "Time zone" },
  pvZoneNote: { zh: "留空表示跟随这台 Mac 的当前时区。", en: "Empty means the Mac's current zone." },
  pvCallTemplate: { zh: "通话链接模板", en: "Call link template" },
  pvCallNote: { zh: "可放 {ref} 与 {node}；留空则提案不带链接。", en: "{ref} and {node} are substituted; empty means proposals carry no link." },
  pvPropTitle: { zh: "等你确认的提案", en: "Proposals awaiting you" },
  pvBookTitle: { zh: "本节点登记的预约", en: "Bookings this node minted" },
  pvAuditTitle: { zh: "本机审计记录", en: "Local audit trail" },
  pvAuditCopy: { zh: "复制记录", en: "Copy trail" },
  pvNone: { zh: "没有待确认的提案", en: "Nothing awaiting a decision" },
  pvNoBookings: { zh: "本节点还没有写入过日历", en: "This node has not written a calendar event yet" },
  pvNoAudit: { zh: "还没有记录", en: "No entries yet" },
  pvStatPending: { zh: "待确认", en: "Awaiting" },
  pvStatBookings: { zh: "已登记预约", en: "Bookings" },
  pvStatDirs: { zh: "可达目录", en: "Reachable dirs" },
  pvStatDirsNote: { zh: "可达数 / 上限", en: "reachable / ceiling" },
  pvBadgePending: { zh: "等你确认", en: "Awaiting you" },
  pvBadgeQuiet: { zh: "无需你处理", en: "Nothing for you" },
  pvActCreate: { zh: "新建日程", en: "create event" },
  pvActReschedule: { zh: "改期", en: "reschedule" },
  pvActCancel: { zh: "取消日程", en: "cancel event" },
  pvActWrite: { zh: "写入文件", en: "write file" },
  pvActOrganize: { zh: "整理文件", en: "organize files" },
  pvActInvoke: { zh: "调用工具", en: "call tool" },
  pvStatePending: { zh: "等你确认", en: "awaiting you" },
  pvStateApproved: { zh: "已批准", en: "approved" },
  pvStateExecuted: { zh: "已执行", en: "executed" },
  pvStateRejected: { zh: "已驳回", en: "rejected" },
  pvStateExpired: { zh: "已过期", en: "expired" },
  pvStateFailed: { zh: "执行失败", en: "execution failed" },
  pvStateCancelled: { zh: "已作废", en: "voided" },
  pvDomainCal: { zh: "日历", en: "calendar" },
  pvDomainWs: { zh: "工作区", en: "workspace" },
  pvDomainMCP: { zh: "MCP", en: "MCP" },
  pvDomainHome: { zh: "家居", en: "home" },
  pvApprove: { zh: "批准并执行", en: "Approve and run" },
  pvReject: { zh: "驳回", en: "Reject" },
  pvConfirmAgain: { zh: "再点一次以确认", en: "Click again to confirm" },
  pvCannotApprove: { zh: "该提案现在无法执行：所需开关或目录已关闭", en: "This one cannot run: the switch or directory it needs is off" },
  pvTtlOver: { zh: "已超时", en: "timed out" },
  decisionDone: { zh: "已按你的决定执行", en: "Your decision was applied" },
  decisionFailed: { zh: "决定未能执行", en: "The decision could not be applied" },
  /* ---- step five: local capability discovery and protocol bridges ---- */
  s5: { zh: "本地中枢桥接", en: "Edge hub bridges" },
  s5Title: { zh: "本地能力发现与协议桥接", en: "Local discovery and protocol bridges" },
  s5Desc: { zh: "只探测这台 Mac 与机主列出的内网地址；每一项能力都默认关闭，启用后仍受同一条二次确认门禁约束。", en: "Only this Mac and the private addresses you list are probed. Every capability starts switched off, and an enabled one still runs through the same second-confirmation gate." },
  hvGuarantee: { zh: "本页全部来自 127.0.0.1：探测不出网、不扫端口、不猜主机；公网地址在建立连接前就被拒绝，计数与原因一并列出。", en: "Everything here is served from the loopback address: no egress, no port sweep, no guessed host. A public target is refused before a socket exists, and the count and reason are listed." },
  hvDiscTitle: { zh: "本地能力发现", en: "Local capability discovery" },
  hvDiscIdle: { zh: "还没有探测结果", en: "Nothing measured yet" },
  hvScan: { zh: "立即探测", en: "Probe now" },
  hvScanning: { zh: "探测中", en: "measuring" },
  hvScanFailed: { zh: "探测失败", en: "The probe failed" },
  hvBoundary: { zh: "仅回环与机主列出的局域网地址", en: "Loopback plus the LAN targets this owner listed" },
  hvKindEngine: { zh: "推理服务", en: "engine" },
  hvKindModel: { zh: "模型", en: "model" },
  hvKindWorkspace: { zh: "工作区", en: "workspace" },
  hvKindCalendar: { zh: "日历", en: "calendar" },
  hvKindLan: { zh: "内网服务", en: "lan" },
  hvKindRefused: { zh: "已拒绝", en: "refused" },
  hvStatePresent: { zh: "在线", en: "present" },
  hvStateAbsent: { zh: "未发现", en: "absent" },
  hvStateInstalled: { zh: "已安装", en: "installed" },
  hvStateAuthorized: { zh: "已授权", en: "authorized" },
  hvStateDenied: { zh: "系统已拒绝", en: "denied by macOS" },
  hvStateOff: { zh: "未开启", en: "off" },
  hvStateReachable: { zh: "端口有响应", en: "reachable" },
  hvStateSilent: { zh: "无响应", en: "silent" },
  hvStateRefused: { zh: "被拒绝", en: "refused" },
  hvStateFull: { zh: "已授权", en: "authorized" },
  hvStateWrite: { zh: "仅写入", en: "write only" },
  hvStateRestricted: { zh: "受限", en: "restricted" },
  hvStateNotAsked: { zh: "尚未询问", en: "not asked yet" },
  hvStateNoBridge: { zh: "未装配", en: "not attached" },
  hvStatCaps: { zh: "能力项", en: "Capabilities" },
  hvStatRefused: { zh: "被拒绝的目标", en: "Refused targets" },
  hvStatRefusedNote: { zh: "未发起任何连接", en: "no connection attempted" },
  hvStatServers: { zh: "MCP 服务器", en: "MCP servers" },
  hvStatServersNote: { zh: "已登记 / 已连接", en: "registered / connected" },
  hvStatEntities: { zh: "可见实体", en: "Visible entities" },
  hvStatEntitiesNote: { zh: "来自白名单", en: "from the allow-list" },
  hvBadgePending: { zh: "等你确认", en: "Awaiting you" },
  hvBadgeOn: { zh: "已启用", en: "Bridges on" },
  hvBadgeOff: { zh: "全部关闭", en: "All off" },
  hvPropTitle: { zh: "待确认的桥接动作", en: "Bridge actions awaiting you" },
  hvPropNone: { zh: "没有等待确认的桥接动作", en: "No bridge action awaits a decision" },
  hvSwitchTitle: { zh: "桥接开关（默认全部关闭）", en: "Bridge switches (all off by default)" },
  hvSwitchNote: { zh: "开关需要背后有可用目标才会真正生效：没有已登记的 MCP 服务器、没有 Home Assistant 或 Broker 地址、没有 CalDAV 服务器时，节点会把它读作关闭。", en: "A switch only takes effect once it has something behind it: with no registered MCP server, no Home Assistant or broker address, and no CalDAV server, the node reads it as off." },
  hvMcpSwitch: { zh: "启用本机 MCP 客户端（stdio 或回环 HTTP）", en: "Enable the local MCP client (stdio or loopback HTTP)" },
  hvHomeSwitch: { zh: "启用 Home Assistant 与 MQTT（仅内网）", en: "Enable Home Assistant and MQTT (private network only)" },
  hvCalDavSwitch: { zh: "启用 CalDAV 空闲时段（仅时段，不读事件内容）", en: "Enable CalDAV free/busy (windows only, never event content)" },
  hvAutoScan: { zh: "打开控制台时自动探测本机能力", en: "Probe local capabilities when the console opens" },
  hvReadonly: { zh: "家居只读：仅镜像状态，不控制设备", en: "Smart home read-only: mirror state, never actuate" },
  hvTelemetry: { zh: "接收 MQTT 状态推送（需填写订阅主题）", en: "Accept MQTT telemetry (needs topic filters)" },
  hvStatusTitle: { zh: "桥接状态", en: "Bridge status" },
  hvStatusIdle: { zh: "尚未查询", en: "not asked yet" },
  hvChecking: { zh: "查询中", en: "asking" },
  hvRefresh: { zh: "重新查询", en: "Ask again" },
  hvGateNote: { zh: "三条状态来自与手机相同的工具入口；只读动作直接执行，变更类动作一律进入待确认提案队列并写入本地审计日志。", en: "All three lines come from the same tool entry points a paired phone uses: read-only calls run, anything mutating becomes a proposal and is written to the local audit log." },
  hvBridgeMCP: { zh: "MCP 客户端", en: "MCP client" },
  hvBridgeHome: { zh: "Home Assistant · MQTT", en: "Home Assistant · MQTT" },
  hvBridgeCalDav: { zh: "CalDAV 空闲时段", en: "CalDAV free/busy" },
  hvHaOk: { zh: "Home Assistant 已配置", en: "Home Assistant configured" },
  hvHaAbsent: { zh: "Home Assistant 未配置", en: "Home Assistant absent" },
  hvMqttOk: { zh: "Broker 已连接", en: "broker connected" },
  hvMqttAbsent: { zh: "Broker 未连接", en: "broker not connected" },
  hvRejectedEntries: { zh: "被拒绝的登记表条目", en: "refused registry entries" },
  hvHaUrl: { zh: "Home Assistant 地址", en: "Home Assistant URL" },
  hvHaNote: { zh: "仅接受回环、10/8、172.16/12、192.168/16 或 .local；公网地址与外部域名在连接前被拒绝。", en: "Loopback, 10/8, 172.16/12, 192.168/16 and .local only; a public address or external domain is refused before a socket exists." },
  hvHaToken: { zh: "长期访问令牌（存入钥匙串）", en: "Long-lived access token (Keychain)" },
  hvMqttHost: { zh: "MQTT 主机", en: "MQTT host" },
  hvMqttHostPlaceholder: { zh: "例如 192.168.1.20", en: "for example 192.168.1.20" },
  hvMqttNote: { zh: "同样是内网边界；MQTT v3.1.1 由本节点直接连接，不经过任何第三方。", en: "The same private-network boundary; the node speaks MQTT v3.1.1 itself, with no third party in between." },
  hvMqttPassword: { zh: "MQTT 口令（存入钥匙串）", en: "MQTT password (Keychain)" },
  hvSecretSave: { zh: "存入钥匙串", en: "Store in Keychain" },
  hvSecretStored: { zh: "凭据已加密存入钥匙串", en: "The credential is stored encrypted" },
  hvMqttPort: { zh: "MQTT 端口", en: "MQTT port" },
  hvSecretFailed: { zh: "凭据未能存入", en: "The credential was not stored" },
  hvSecretEmpty: { zh: "请先填写凭据", en: "Write the credential first" },
  hvServerRequired: { zh: "请先填写 CalDAV 服务器标识", en: "Name the CalDAV server first" },
  hvCalDavId: { zh: "CalDAV 服务器标识", en: "CalDAV server id" },
  hvCalDavIdNote: { zh: "必须与设置文档中已登记的标识一致。", en: "Must match a server already listed in the settings document." },
  hvCalDavPassword: { zh: "CalDAV 口令或应用专用密码", en: "CalDAV password or app token" },
  hvCalDavPasswordNote: { zh: "同样是只存引用；节点不会把口令写入设置、日志或本页任何回包。", en: "Reference only, again: the node never puts the value in the settings file, a log line, or any reply this page reads." },
  hvEntitiesTitle: { zh: "设备实体白名单", en: "Entity allow-list" },
  hvEntityAdd: { zh: "添加实体", en: "Add entity" },
  hvEntityNote: { zh: "不在此列表中的实体对本节点不存在。门锁、撤防、警号、摄像机与扫地机即使已列入，也必须经过二次确认才能控制。", en: "An entity that is not listed here does not exist for this node. Locks, alarms, sirens, cameras and vacuums need the second confirmation even when they are listed." },
  hvEntityEmpty: { zh: "白名单为空：桥接将读作关闭", en: "The allow-list is empty, so the bridge reads as off" },
  hvEntityLimit: { zh: "白名单已达上限", en: "The allow-list is at its ceiling" },
  hvTargetsTitle: { zh: "局域网探测目标（可选）", en: "LAN probe targets (optional)" },
  hvTargetAdd: { zh: "添加目标", en: "Add target" },
  hvTargetNote: { zh: "格式为 主机:端口。仅一次 TCP 连接尝试，350 毫秒超时；公网地址会被拒绝并计入上面的「被拒绝的目标」。", en: "Host and port. One TCP attempt with a 350 ms timeout; a public address is refused and counted under refused targets above." },
  hvTargetEmpty: { zh: "未列出目标：仅探测本机", en: "No target listed, so only this Mac is probed" },
  hvTargetLimit: { zh: "探测目标已达上限", en: "The probe list is at its ceiling" },
  upTitle: { zh: "签名更新", en: "Signed updates" },
  upDesc: { zh: "只向机主固定的一项官方清单发起 HTTPS 请求；验签失败或版本不高于当前版本时静默忽略。", en: "One owner-pinned HTTPS manifest is the only fetch; a bad signature or a version that is not newer is ignored without a card." },
  upCheck: { zh: "检查更新", en: "Check for updates" },
  upChecking: { zh: "检查中", en: "checking" },
  upCheckFailed: { zh: "检查失败", en: "The check failed" },
  upFound: { zh: "发现新版本", en: "A new version is available" },
  upUpToDate: { zh: "已是最新版本", en: "Already current" },
  upIgnored: { zh: "已静默忽略", en: "ignored quietly" },
  upFailed: { zh: "更新操作失败", en: "The update action failed" },
  upDone: { zh: "已完成", en: "done" },
  upBadgeReady: { zh: "等你确认", en: "Awaiting you" },
  upBadgeOn: { zh: "已启用", en: "Updates on" },
  upBadgeIncomplete: { zh: "配置不完整", en: "Incomplete" },
  upBadgeOff: { zh: "未启用", en: "Updates off" },
  upCurrent: { zh: "当前版本", en: "Current version" },
  upKey: { zh: "清单公钥指纹", en: "Manifest key" },
  upLastCheck: { zh: "上次检查", en: "Last check" },
  upInstalled: { zh: "已安装", en: "installed" },
  upPendingTitle: { zh: "新版本可安装", en: "ready to install" },
  upNoPending: { zh: "没有待处理的版本", en: "No release awaits a decision" },
  upBuild: { zh: "构建", en: "build" },
  upReleased: { zh: "发布日期", en: "released" },
  upPackage: { zh: "安装包", en: "package" },
  upSummary: { zh: "更新说明", en: "What is new" },
  upApprove: { zh: "立即更新", en: "Update now" },
  upSnooze: { zh: "稍后提醒", en: "Remind me later" },
  upConfirmAgain: { zh: "再点一次确认", en: "Click again to confirm" },
  upRefused: { zh: "已拒绝", en: "refused" },
  upConfigTitle: { zh: "更新来源（仅机主配置）", en: "Update feed (owner configured)" },
  upSwitchNote: { zh: "清单位置与公钥都由你填写；节点不会从清单自身的主机获取公钥，也不会跟随重定向。", en: "You supply both the manifest and the key; the node never fetches a key from the manifest host and never follows a redirect." },
  upEnabled: { zh: "启用签名更新检查", en: "Enable signed update checks" },
  upManifestURL: { zh: "清单地址", en: "Manifest URL" },
  upManifestNote: { zh: "必须是 https、端口 443，且主机名与你填写的一致；重定向一律拒绝。", en: "Must be https on port 443 with exactly the host you typed; every redirect is refused." },
  upPublicKey: { zh: "Ed25519 公钥（base64url）", en: "Ed25519 public key (base64url)" },
  upKeyNote: { zh: "32 字节公钥；指纹显示在上面的统计里，验签只用这个值。", en: "A 32-byte key; its fingerprint appears in the stats above and verification uses only this value." },
  upPackageHosts: { zh: "允许的安装包主机（逗号分隔）", en: "Allowed package hosts (comma separated)" },
  upPackageNote: { zh: "清单主机始终被允许；这里只添加签名清单可能指向的额外主机，例如 CDN。", en: "The manifest host is always allowed; list only extra hosts a signed manifest may point at, such as a CDN." },
  upInterval: { zh: "检查间隔（分钟）", en: "Check interval (minutes)" },
  upSnoozeHours: { zh: "稍后提醒时长（小时）", en: "Snooze length (hours)" },
  upGateNote: { zh: "检测是自动的，安装不是：在你点击「立即更新」之前，节点不会下载任何安装包；下载后先核对字节数与 SHA-256，再交给 macOS 打开。", en: "Detection is automatic, installation is not: nothing is downloaded before you press Update now, and a downloaded package is checked for byte size and SHA-256 before macOS opens it." },
  dcFeedTitle: { zh: "最新发现", en: "Latest items" },
  dcEmpty: { zh: "还没有条目，点「立即刷新」", en: "No items yet; press refresh" },
  dcRefresh: { zh: "立即刷新", en: "Refresh now" },
  dcRefreshing: { zh: "刷新中", en: "refreshing" },
  dcRefreshFailed: { zh: "刷新失败", en: "The refresh failed" },
  dcRefreshNote: { zh: "卡片只带可读摘要；带签名的完整载荷是 feed.json，随同一条加密会话送达，并写入本地审计日志。", en: "The card carries a readable index; the signed payload is feed.json, delivered in the same encrypted session and written to the local audit log." },
  dcConfigTitle: { zh: "聚合配置", en: "Aggregator settings" },
  dcSwitchNote: { zh: "默认关闭；即使打开，没有本地文件夹、RSS/JSON 源或 MCP 源时仍读作关闭。", en: "Off by default; even switched on it reads as off until a folder, feed or MCP source exists." },
  dcEnabled: { zh: "启用发现聚合", en: "Enable the Discover aggregator" },
  dcBadgeOn: { zh: "已启用", en: "Aggregator on" },
  dcBadgeOff: { zh: "未启用", en: "Aggregator off" },
  dcInterval: { zh: "刷新间隔（分钟）", en: "Refresh interval (minutes)" },
  dcMaxItems: { zh: "每次最多条目", en: "Maximum items per run" },
  dcFoldersTitle: { zh: "本地文件夹（只读文本）", en: "Local folders (text only)" },
  dcFolderAdd: { zh: "添加文件夹", en: "Add folder" },
  dcFolderNote: { zh: "只读取你主目录内的纯文本类文件；符号链接、超限文件与层级过深的位置会被跳过。", en: "Only plain-text files under your home folder are read; symlinks, oversize files and folders nested too deep are skipped." },
  dcFolderEmpty: { zh: "未添加文件夹", en: "No folder added" },
  dcFolderLimit: { zh: "文件夹已达上限", en: "The folder list is at its ceiling" },
  dcFeedsTitle: { zh: "RSS / JSON 源（仅内网）", en: "RSS / JSON feeds (private network only)" },
  dcFeedAdd: { zh: "添加源", en: "Add feed" },
  dcFeedOn: { zh: "启用", en: "on" },
  dcFeedNote: { zh: "公网地址在发起连接前由 EdgeBoundary 拒绝；被拒绝的源会显示在下方状态里。", en: "A public address is refused by EdgeBoundary before a socket exists and appears in the source status below." },
  dcFeedEmpty: { zh: "未添加源", en: "No feed added" },
  dcFeedLimit: { zh: "源已达上限", en: "The feed list is at its ceiling" },
  dcMcpTitle: { zh: "MCP 只读源", en: "Read-only MCP sources" },
  dcMcpAdd: { zh: "添加 MCP 源", en: "Add MCP source" },
  dcMcpNote: { zh: "只允许只读工具；变更类工具永远不会因为聚合而被运行。", en: "Read-only tools only; a mutating tool is never run by the aggregator." },
  dcMcpEmpty: { zh: "未添加 MCP 源", en: "No MCP source added" },
  dcMcpLimit: { zh: "MCP 源已达上限", en: "The MCP list is at its ceiling" },
  dcSourcesTitle: { zh: "源状态", en: "Source status" },
  dcSourcesIdle: { zh: "尚未运行", en: "not run yet" },
  dcSourcesNote: { zh: "每次刷新都会写入本地审计日志；推送仍走已绑定的端到端会话。", en: "Every run is written to the local audit log; delivery still uses the bound end-to-end session." },
  dcStatItems: { zh: "条目", en: "Items" },
  dcStatSources: { zh: "源", en: "Sources" },
  dcStatLastRun: { zh: "上次运行", en: "Last run" },
  dcStatDelivered: { zh: "上次推送", en: "Last delivered" },
  dcKindFolder: { zh: "文件夹", en: "folder" },
  dcKindRSS: { zh: "RSS / Atom", en: "RSS / Atom" },
  dcKindJSON: { zh: "JSON 源", en: "JSON feed" },
  dcKindMCP: { zh: "MCP", en: "MCP" },
  dcStateOk: { zh: "正常", en: "ok" },
  dcStateRefused: { zh: "已拒绝", en: "refused" },
  geTitle: { zh: "全球情报地图（God's Eye View）", en: "Global intelligence map (God's Eye View)" },
  geDesc: { zh: "独立第三方程序，由你本机安装并运行；本节点只校验固定版本、以 127.0.0.1 启动它，并把已验证的 MCP 入口登记为只读优先的工具。", en: "A separate third-party program that you install and run on this Mac; this node only verifies a pinned version, launches it on 127.0.0.1, and registers the verified MCP entry as a read-first tool." },
  geStart: { zh: "启动", en: "Start" },
  geStop: { zh: "停止", en: "Stop" },
  geHealth: { zh: "检查", en: "Check" },
  geBadgeRunning: { zh: "运行中", en: "Running" },
  geBadgeOn: { zh: "已启用", en: "On" },
  geBadgeOff: { zh: "未启用", en: "Off" },
  geStatNode: { zh: "Node.js", en: "Node.js" },
  geStatInstall: { zh: "安装校验", en: "Install" },
  geStatPort: { zh: "回环端口", en: "Loopback port" },
  geStatHealth: { zh: "健康检查", en: "Health" },
  geRunning: { zh: "运行中", en: "running" },
  geStopped: { zh: "已停止", en: "stopped" },
  geAbsent: { zh: "未检测到", en: "absent" },
  geUnverified: { zh: "未校验", en: "unverified" },
  geNoPath: { zh: "未绑定", en: "unbound" },
  geStatePath: { zh: "安装目录", en: "Install directory" },
  geStateMode: { zh: "模式", en: "Mode" },
  geStateProcess: { zh: "本地进程", en: "Local process" },
  geStateVerified: { zh: "上次校验", en: "Last verified" },
  geStateError: { zh: "最近错误", en: "Last error" },
  geModeExisting: { zh: "仅绑定现有安装", en: "Bind an existing install" },
  geModePinned: { zh: "拉取固定版本", en: "Clone a pinned version" },
  geMode: { zh: "安装方式", en: "Install mode" },
  geModeNote: { zh: "固定版本模式在一次点击后克隆指定 commit，需要显式打开网络拉取。", en: "The pinned mode clones one commit after a click and requires the network pull switch." },
  geMcpTitle: { zh: "MCP 工具", en: "MCP tools" },
  geMcpRegister: { zh: "重新注册", en: "Re-register" },
  geMcpSync: { zh: "同步工具", en: "Sync tools" },
  geMcpUnregister: { zh: "移除注册", en: "Unregister" },
  geMcpRegistered: { zh: "已注册", en: "registered" },
  geMcpOff: { zh: "未注册", en: "not registered" },
  geToolsIdle: { zh: "启动并同步后，这里会列出已登记的工具", en: "Tools appear here after a start and a sync" },
  geToolRead: { zh: "只读", en: "read-only" },
  geToolWrite: { zh: "写操作 · 需批准", en: "write · approval" },
  geConfigTitle: { zh: "程序与端口（仅机主配置）", en: "Program and port (owner configured)" },
  geSwitch: { zh: "启用全球情报地图", en: "Enable God's Eye View" },
  geSwitchNote: { zh: "默认关闭。先保存开关与路径，再点「启动」；本节点不会在开机时自行运行它。", en: "Off by default. Save the switch and paths first, then press Start; this node never runs it at boot." },
  gePath: { zh: "安装目录", en: "Install directory" },
  gePathPlaceholder: { zh: "~/Tools/gods-eye-view", en: "~/Tools/gods-eye-view" },
  gePathNote: { zh: "绝对路径或以 ~ 开头；系统目录、钥匙串目录与本节点数据目录会被拒绝。", en: "An absolute or ~ path; system, Keychain and node-data directories are refused." },
  geVersion: { zh: "固定版本", en: "Pinned version" },
  geVersionNote: { zh: "package.json 必须报告这个版本，否则拒绝启动。", en: "package.json must report exactly this version or the start is refused." },
  gePort: { zh: "回环端口", en: "Loopback port" },
  gePortNote: { zh: "只绑定 127.0.0.1；端口已被占用时拒绝启动。", en: "Bound to 127.0.0.1 only; an occupied port is refused." },
  geNodePath: { zh: "Node.js 可执行文件", en: "Node.js executable" },
  geNodePlaceholder: { zh: "留空则自动检测", en: "empty means auto-detect" },
  geNodeNote: { zh: "需要 Node.js 20 或更新；留空时用 PATH 中的 node。", en: "Requires Node.js 20 or newer; empty uses node from PATH." },
  gePull: { zh: "允许一次性拉取固定 commit", en: "Allow a one-time pinned clone" },
  gePullNote: { zh: "默认关闭；只在你点击「安装」时联网，并用 40 位 commit 校验 HEAD。", en: "Off by default; only the Install click dials, and HEAD must equal the 40-hex commit." },
  geRepo: { zh: "源码仓库（https）", en: "Source repository (https)" },
  geRepoNote: { zh: "不允许凭据、查询参数或片段。", en: "No credentials, query or fragment." },
  geRef: { zh: "固定 tag 或分支", en: "Pinned tag or branch" },
  geRefNote: { zh: "与 commit 一起使用；标签移动不会改变实际运行的内容。", en: "Used with the commit; a moved tag cannot change what runs." },
  geCommit: { zh: "固定 commit（40 位）", en: "Pinned commit (40 hex)" },
  geCommitNote: { zh: "克隆后 HEAD 必须与之完全一致。", en: "The clone's HEAD must equal it exactly." },
  geVerify: { zh: "校验安装", en: "Verify install" },
  geInstall: { zh: "安装 / 校验", en: "Install / verify" },
  geInstallNote: { zh: "现有模式只校验不拉取；固定版本模式会先克隆到临时目录，校验通过后才替换目标。", en: "Existing mode only verifies; pinned mode clones into a staging directory and replaces the target only after it verifies." },
  geCredTitle: { zh: "可选数据源（macOS 钥匙串）", en: "Optional feeds (macOS Keychain)" },
  geCredNote: { zh: "值只写入钥匙串，设置文件只记引用；启动时作为环境变量交给本机程序，绝不出现在页面、审计或快照中。", en: "Values go only to the Keychain; settings hold references, which become launch-time environment variables and never appear in the page, the audit or a snapshot." },
  geCredStore: { zh: "存入钥匙串", en: "Store in Keychain" },
  geCredMissing: { zh: "未存入", en: "not stored" },
  geSourceOn: { zh: "启动时交给本机程序", en: "hand to the local program at launch" },
  geCredEmpty: { zh: "凭据为空", en: "The credential is empty" },
  geCredStored: { zh: "已存入钥匙串", en: "Stored in the Keychain" },
  geCredFailed: { zh: "凭据存入失败", en: "The credential was not stored" },
  geActionFailed: { zh: "操作失败", en: "The action failed" },
  geActionDone: { zh: "已受理", en: "Accepted" },
  geSaveFirst: { zh: "请先保存配置，再启动", en: "Save the settings before starting" },
  dcStateFailed: { zh: "失败", en: "failed" },
  dcStateOff: { zh: "已停用", en: "off" },
  dcLabel: { zh: "名称", en: "label" },
  dcUrl: { zh: "地址", en: "URL" },
  dcKindField: { zh: "类型", en: "kind" },
  dcServer: { zh: "服务器标识", en: "server id" },
  dcTool: { zh: "工具名", en: "tool" },
  dcArgs: { zh: "参数 JSON", en: "arguments JSON" },
  hvRemove: { zh: "移除", en: "remove" },
  /* ---- personal assistant ---- */
  asTitle: { zh: "私人助手", en: "Private assistant" },
  asDesc: { zh: "统一的连接器权限与本地定时任务；任何写操作都必须由机主在手机卡片或本地控制台批准，执行层校验签名回执。", en: "Unified connector permissions and local schedules. Every write needs the owner's approval on a phone card or in this console, and the executor verifies the signed receipt." },
  asBadgeOn: { zh: "已开启", en: "on" },
  asBadgeOff: { zh: "已关闭", en: "off" },
  asBadgePending: { zh: "待审批", en: "pending" },
  asStatPending: { zh: "待审批", en: "Pending" },
  asStatPendingNote: { zh: "批准前不会执行", en: "nothing runs before approval" },
  asStatDrafts: { zh: "邮件草稿", en: "Drafts" },
  asStatDraftsNote: { zh: "正文只留在本机", en: "the body stays on this Mac" },
  asStatConnectors: { zh: "已接入", en: "Connectors on" },
  asStatConnectorsNote: { zh: "默认只读或提案", en: "read or propose only" },
  asStatMail: { zh: "邮箱", en: "Mail" },
  asMailReady: { zh: "凭据齐备", en: "credentials stored" },
  asMailMissing: { zh: "凭据未齐", en: "credentials missing" },
  asSwitchesTitle: { zh: "定时任务", en: "Local schedules" },
  asSwitchNote: { zh: "默认关闭；保存后由机主开启，重启仍保留。", en: "Off by default; save, then enable. The choice survives a restart." },
  asMaster: { zh: "私人助手总开关", en: "Assistant master switch" },
  asBriefingSwitch: { zh: "每日私人简报", en: "Daily private briefing" },
  asPatrolSwitch: { zh: "家庭设备巡检", en: "Home device patrol" },
  asMailSwitch: { zh: "邮件只读整理", en: "Read-only mail triage" },
  asBriefHour: { zh: "简报小时", en: "Briefing hour" },
  asBriefHourNote: { zh: "本机时间 0–23", en: "local time, 0–23" },
  asBriefMinute: { zh: "简报分钟", en: "Briefing minute" },
  asBriefMinuteNote: { zh: "0–59", en: "0–59" },
  asPatrolInterval: { zh: "巡检间隔（分钟）", en: "Patrol interval (minutes)" },
  asPatrolIntervalNote: { zh: "5–1440 分钟", en: "5–1440 minutes" },
  asPatrolOffline: { zh: "离线阈值（分钟）", en: "Offline threshold (minutes)" },
  asPatrolOfflineNote: { zh: "超过该时长才生成提案", en: "a proposal is made only after this long" },
  asImapHost: { zh: "IMAP 主机", en: "IMAP host" },
  asImapHostNote: { zh: "仅隐式 TLS，端口 993；不做服务发现", en: "implicit TLS only, port 993; no discovery" },
  asImapPort: { zh: "IMAP 端口", en: "IMAP port" },
  asSmtpHost: { zh: "SMTP 主机", en: "SMTP host" },
  asSmtpHostNote: { zh: "仅隐式 TLS，端口 465；不自动探测", en: "implicit TLS only, port 465; no probing" },
  asSmtpPort: { zh: "SMTP 端口", en: "SMTP port" },
  asPortNote: { zh: "只有 993 与 465 可用", en: "only 993 and 465 are usable" },
  asMailUser: { zh: "邮箱账号", en: "Mail account" },
  asMailUserNote: { zh: "只用于登录，不写日志", en: "used to sign in only, never logged" },
  asMailFrom: { zh: "发件地址", en: "From address" },
  asMailFromNote: { zh: "回复草稿的 From", en: "the From of reply drafts" },
  asLookback: { zh: "回看天数", en: "Lookback days" },
  asLookbackNote: { zh: "1–14 天", en: "1–14 days" },
  asMaxMessages: { zh: "每次封数", en: "Messages per run" },
  asMaxMessagesNote: { zh: "1–30 封", en: "1–30 messages" },
  asBriefingNow: { zh: "立即生成简报", en: "Briefing now" },
  asPatrolNow: { zh: "立即巡检", en: "Patrol now" },
  asMailNow: { zh: "立即整理邮件", en: "Triage mail now" },
  asSaveFirst: { zh: "请先保存并开启私人助手", en: "Save and enable the assistant first" },
  asRunDone: { zh: "已完成", en: "Done" },
  asRunFailed: { zh: "执行失败", en: "The run failed" },
  asConnectorsTitle: { zh: "连接器权限", en: "Connector permissions" },
  asConnectorsIdle: { zh: "尚未装配", en: "Not assembled yet" },
  asConnectorsNote: { zh: "read 只读、propose 出草稿；write 必须先有签名回执。", en: "read collects, propose drafts; a write needs a signed receipt first." },
  asPermRead: { zh: "只读", en: "read" },
  asPermPropose: { zh: "提案", en: "propose" },
  asPermWrite: { zh: "写入", en: "write" },
  asPermAdmin: { zh: "管理", en: "admin" },
  asKindCalendar: { zh: "日历", en: "calendar" },
  asKindCalDav: { zh: "CalDAV 日程", en: "CalDAV" },
  asKindSmartHome: { zh: "智能家居", en: "smart home" },
  asKindMcp: { zh: "MCP 工具", en: "MCP" },
  asKindGodsEye: { zh: "全球情报地图", en: "God's Eye View" },
  asKindMail: { zh: "邮件", en: "mail" },
  asKindOther: { zh: "其他连接器", en: "other" },
  asMailCredsTitle: { zh: "邮箱凭据（钥匙串引用）", en: "Mail credentials (Keychain references)" },
  asCredImap: { zh: "IMAP 密码", en: "IMAP password" },
  asCredSmtp: { zh: "SMTP 密码", en: "SMTP password" },
  asCredPlaceholder: { zh: "应用专用密码", en: "app-specific password" },
  asCredStore: { zh: "存入钥匙串", en: "Store in Keychain" },
  asCredStored: { zh: "已存入", en: "stored" },
  asCredMissing: { zh: "未存入", en: "missing" },
  asCredEmpty: { zh: "请输入密码", en: "Enter the password" },
  asCredFailed: { zh: "凭据存入失败", en: "The credential was not stored" },
  asCredNote: { zh: "值只进 macOS 钥匙串，快照与审计只有引用；先保存并开启私人助手再存。", en: "The value goes only to the macOS Keychain; snapshots and the audit log carry the reference. Save and enable the assistant first." },
  asPendingTitle: { zh: "待审批提案", en: "Pending approvals" },
  asPendingIdle: { zh: "没有待审批的提案", en: "Nothing waiting" },
  asTtl: { zh: "剩余", en: "left" },
  asCancelAll: { zh: "撤销全部待审批", en: "Cancel all pending" },
  asPendingNote: { zh: "卡片只带目标与摘要，回执在手机卡片或控制台内生成。", en: "Cards carry the target and digest; the receipt is minted on the phone card or inside this node." },
  asAuditTitle: { zh: "本地审计（SQLite）", en: "Local audit (SQLite)" },
  asAuditIdle: { zh: "还没有记录", en: "No entries yet" },
  asDecisionDone: { zh: "已执行", en: "Applied" },
  asDecisionFailed: { zh: "未执行", en: "Not applied" },
  asRepairsTitle: { zh: "关键设备与修复动作", en: "Critical devices and repair actions" },
  asRepairOn: { zh: "启用", en: "on" },
  asRepairsEmpty: { zh: "尚未登记关键设备", en: "No critical device registered" },
  asRepairsFull: { zh: "已达上限", en: "The limit is reached" },
  asRepairAdd: { zh: "添加规则", en: "Add rule" },
  asRepairsNote: { zh: "巡检只读；修复动作仅在批准后执行一次。", en: "The patrol is read-only; a repair runs once, only after approval." }
};

/* ------------------------------------------------------- locale registry */
/* `LOCALES` is replaced at document build time with `ConsoleLanguage
   .displayOrder` — the same 17 languages the POPOPX iOS app ships
   (apps/ios/POPOPX.xcodeproj `knownRegions` without `Base`, which is an Xcode
   artefact rather than a locale) plus `zh-Hant`, which the phone does not
   offer, and `system`, which follows the Mac's per-app language exactly the way
   the phone follows iOS's Display Language setting. Generating it from Swift is
   what keeps the two apps from offering different lists.

   `catalog` is the honest coverage boundary: the hand-written interface copy is
   maintained in Simplified Chinese and English, so every other language in this
   list is offered and stored but rendered from the English catalog until its own
   catalog lands. The page says so out loud instead of pretending.

   `zh-Hant` is the exception, and `HANT` below is how: it is this page's own
   Simplified column converted with Apple's CoreFoundation `Hans-Hant` transform
   (see `TraditionalChinese`), injected at build time. A derived catalog cannot
   fall behind the hand-written one, because it *is* the hand-written one. */
var LOCALES = /*PPX_LANGS*/[];

var HANT = /*PPX_HANT*/{};

/* The local model list is generated from `ModelCatalog`, so the picker can never
   name a reference the node will not resolve. Nothing machine-dependent is in it:
   the page stays byte-identical on every launch, which is what makes the CSP
   defensible. The verdicts are computed here from the emitted thresholds because
   a static document cannot know this Mac's memory; the authoritative verdict for
   the model actually running arrives on the snapshot as `plan.rationale`. */
var MODELS = /*PPX_MODELS*/{models: [],admission: []};

function localeEntry(code) {
  for (var i = 0; i < LOCALES.length; i += 1) { if (LOCALES[i].code === code) { return LOCALES[i]; } }
  return null;
}

function localeKnown(code) { return code === "system" || localeEntry(code) !== null; }

function normaliseTag(tag) {
  var parts = String(tag || "").toLowerCase().replace(/_/g, "-").split("-");
  if (!parts.length || !parts[0]) { return "en"; }
  /* The phone ships one Chinese catalog, zh-Hans, so zh / zh-CN / zh-Hant all
     resolve to it rather than to a locale that exists in neither app. */
  if (parts[0] === "zh") { return "zh-Hans"; }
  var joined = parts.join("-");
  for (var i = 0; i < LOCALES.length; i += 1) {
    var code = LOCALES[i].code;
    if (code.toLowerCase() === joined || code.toLowerCase() === parts[0]) { return code; }
  }
  return "en";
}

function systemLocale() {
  var tags = [];
  if (navigator.languages && navigator.languages.length) { tags = navigator.languages.slice(); }
  tags.push(navigator.language || "");
  for (var i = 0; i < tags.length; i += 1) {
    var raw = String(tags[i] || "");
    if (!raw) { continue; }
    var code = normaliseTag(raw);
    /* normaliseTag answers "en" for both a real English preference and an
       unknown one; only the first is a decision, the other keeps scanning. */
    if (code !== "en" || raw.toLowerCase().replace(/_/g, "-").indexOf("en") === 0) { return code; }
  }
  return "en";
}

function catalogFor(code) {
  var entry = code === "system" ? localeEntry(systemLocale()) : localeEntry(code);
  if (!entry) { return "en"; }
  return entry.catalog || "en";
}

/* One lookup rule for every surface, so a string cannot be Traditional in a
   label and Simplified in a tooltip. */
function catalogValue(key, catalog) {
  var row = I18N[key];
  if (!row) { return null; }
  if (catalog === "zhHant") { return HANT[key] || row.en || null; }
  return row[catalog] || row.en || null;
}

function uiIsChinese() { return catalogFor(S.lang) !== "en"; }

/* Dynamic copy that travels on the snapshot (engine names, checklist titles)
   arrives as `xZh` / `xHant` / `xEn`; the node generates all three because one
   snapshot is broadcast to every tab. */
function snapshotField(object, base) {
  var suffix = { zh: "Zh", zhHant: "Hant", en: "En" }[catalogFor(S.lang)];
  var value = object[base + suffix];
  if (value) { return String(value); }
  return String(object[base + "En"] || object[base + "Zh"] || "");
}

var S = {
  lang: "system",
  langPending: false,
  langAdopted: false,
  snap: null,
  step: 1,
  entries: [],
  seen: {},
  autoScroll: true,
  logStep: 0,
  logFilter: "all",
  form: null,
  formBuilt: false,
  formBase: 0,
  dirty: false,
  saving: false,
  hadTunnel: false,
  expiredRendered: false,
  pvCheck: null,
  discovery: null,
  hub: null,
  hubPending: false,
  clockOffset: 0,
  es: null,
  esBackoff: 1000,
  esTimer: null,
  refreshTimer: null,
  devOpen: false,
  rawText: "",
  copyable: {},
  modelPull: "",
  qrNonce: 0,
  engineKeys: "",
  engineRows: {},
  gauge: null,
  drillResult: null,
  booted: false
};

/* -------------------------------------------------------------- helpers */
function t(key) { var value = catalogValue(key, catalogFor(S.lang)); return value === null ? "" : value; }
function el(id) { return document.getElementById(id); }

function h(tag, attrs, kids) {
  var node = document.createElement(tag);
  if (attrs) {
    Object.keys(attrs).forEach(function (key) {
      var value = attrs[key];
      if (value === null || value === undefined || value === false) { return; }
      if (key === "text") { node.textContent = String(value); }
      else if (key === "cls") { node.className = value; }
      else if (key === "html") { throw new Error("markup injection is not allowed"); }
      else if (key === "on") { Object.keys(value).forEach(function (ev) { node.addEventListener(ev, value[ev]); }); }
      else if (key === "style") { Object.keys(value).forEach(function (p) { node.style.setProperty(p, value[p]); }); }
      else if (key === "hidden") { if (value) { node.hidden = true; } }
      else { node.setAttribute(key, String(value)); }
    });
  }
  (Array.isArray(kids) ? kids : (kids === null || kids === undefined ? [] : [kids])).forEach(function (kid) {
    if (kid === null || kid === undefined || kid === false) { return; }
    node.appendChild(typeof kid === "object" ? kid : document.createTextNode(String(kid)));
  });
  return node;
}
function clear(node) { while (node && node.firstChild) { node.removeChild(node.firstChild); } }
function setText(id, value) { var node = el(id); if (node) { node.textContent = value === null || value === undefined ? "" : String(value); } }
function show(id, on) { var node = el(id); if (node) { node.hidden = !on; } }

function fmt(n, digits) {
  if (n === null || n === undefined || isNaN(Number(n))) { return "—"; }
  var value = Number(n);
  var fixed = digits === undefined ? (value >= 100 || value === Math.trunc(value) ? 0 : 1) : digits;
  return value.toFixed(fixed);
}
function bytes(b) {
  if (b === null || b === undefined || isNaN(Number(b))) { return "—"; }
  var units = ["B", "KB", "MB", "GB", "TB", "PB"];
  var value = Number(b);
  var index = 0;
  while (value >= 1024 && index < units.length - 1) { value /= 1024; index += 1; }
  return (index === 0 ? String(value) : value.toFixed(1)) + " " + units[index];
}
function clockOf(date) {
  if (!date) { return "--:--:--"; }
  function pad(x) { return x < 10 ? "0" + x : String(x); }
  return pad(date.getHours()) + ":" + pad(date.getMinutes()) + ":" + pad(date.getSeconds());
}
function stampOf(date) {
  if (!date) { return t("never"); }
  return clockOf(date);
}
function dateOf(value) { return value ? new Date(value) : null; }
function relTime(date) {
  if (!date) { return t("never"); }
  var seconds = Math.max(0, Math.round((nodeNow() - date.getTime()) / 1000));
  if (seconds < 60) { return seconds + t("secondsUnit") + " " + t("ago"); }
  if (seconds < 3600) { return Math.round(seconds / 60) + "m " + t("ago"); }
  return Math.round(seconds / 3600) + "h " + t("ago");
}
function nodeNow() { return Date.now() + S.clockOffset; }
function dur(seconds) {
  if (seconds === null || seconds === undefined) { return "—"; }
  var s = Math.max(0, Math.round(Number(seconds)));
  var parts = [];
  var d = Math.floor(s / 86400); s -= d * 86400;
  var hh = Math.floor(s / 3600); s -= hh * 3600;
  var mm = Math.floor(s / 60); s -= mm * 60;
  if (d) { parts.push(d + "d"); }
  parts.push((d ? zero2(hh) : String(hh)) + ":" + zero2(mm) + ":" + zero2(s));
  return parts.join(" ");
}
function zero2(x) { return x < 10 ? "0" + x : String(x); }
function anon(path) {
  if (!path) { return ""; }
  return String(path).replace(/^\/Users\/[^/]+/, "~").replace(/^\/home\/[^/]+/, "~");
}
function hashKey(text) {
  var value = String(text === null || text === undefined ? "" : text);
  var hash = 5381;
  for (var i = 0; i < value.length; i += 1) { hash = ((hash << 5) + hash) ^ value.charCodeAt(i); }
  return (hash >>> 0).toString(36);
}
function clone(object) { return JSON.parse(JSON.stringify(object === undefined ? null : object)); }

/* ------------------------------------------------------------------ api */
function APIError(message, status, path) {
  this.name = "APIError";
  this.message = message;
  this.status = status;
  this.path = path;
}
APIError.prototype = Object.create(Error.prototype);

function api(path, options) {
  var opts = options || {};
  var init = { method: opts.method || "GET", headers: {}, cache: "no-store" };
  init.headers["X-PPX-Token"] = TOKEN;
  if (opts.accept === "png") { init.headers["Accept"] = "image/png"; }
  else if (opts.raw) { init.headers["Accept"] = "application/json"; }
  else { init.headers["Accept"] = "application/json"; }
  if (opts.json !== undefined) {
    init.headers["Content-Type"] = "application/json";
    init.body = JSON.stringify(opts.json);
  }
  var url = path;
  if (opts.query) {
    var params = new URLSearchParams();
    Object.keys(opts.query).forEach(function (key) { params.set(key, String(opts.query[key])); });
    url = path + (path.indexOf("?") >= 0 ? "&" : "?") + params.toString();
  }
  return fetch(url, init).then(function (response) {
    if (!response.ok) {
      return response.text().then(function (text) {
        var message = text;
        try {
          var parsed = JSON.parse(text);
          if (parsed && parsed.error) { message = String(parsed.error); }
        } catch (ignored) { /* plain text or empty body is fine */ }
        if (response.status === 401) { message = message || "401"; }
        throw new APIError(message || (response.status + " " + response.statusText), response.status, path);
      });
    }
    if (opts.raw) { return response.text(); }
    if (response.status === 204) { return null; }
    var header = (response.headers.get("content-type") || "");
    if (header.indexOf("json") < 0) { return response.text(); }
    return response.json();
  });
}

/* ---------------------------------------------------------------- toast */
function toast(kind, text) {
  var host = el("toasts");
  if (!host) { return; }
  var node = h("div", { cls: "toast", "data-kind": kind }, [
    h("span", { text: text }),
    h("button", { cls: "toast__x", text: "×", aria: { label: "close" }, onclick: "PPX.dismiss(this)" })
  ]);
  host.appendChild(node);
  window.setTimeout(function () { if (node.parentNode) { node.parentNode.removeChild(node); } }, kind === "err" ? 6200 : 4200);
  while (host.children.length > 4) { host.removeChild(host.firstChild); }
}
function fail(kind, error) {
  toast("err", t(kind) + " · " + (error && error.message ? error.message : String(error)));
}

/* --------------------------------------------------------------- icons  */
/* Static, hard-coded path table. Values are constants in this file — never
   remote data — so injecting them as markup cannot carry attacker input. */
var ICONS = {
  done: '<path d="M20 6 9 17l-5-5"/>',
  todo: '<circle cx="12" cy="12" r="8"/><path d="M12 8v4l3 2"/>',
  run: '<circle cx="12" cy="12" r="8" stroke-dasharray="12 8"/>',
  wait: '<path d="M12 3 2 20h20L12 3z"/><path d="M12 10v5"/><path d="M12 17.5v.5"/>',
  brain: '<path d="M9 4a3 3 0 0 1 3 3v10a3 3 0 0 1-6 0V7a3 3 0 0 1 3-3z"/><path d="M15 4a3 3 0 0 0-3 3v10a3 3 0 0 0 6 0V7a3 3 0 0 0-3-3z"/>',
  waves: '<path d="M2 9c2 0 2 2 4 2s2-2 4-2 2 2 4 2 2-2 4-2 2 2 4 2"/><path d="M2 15c2 0 2 2 4 2s2-2 4-2 2 2 4 2 2-2 4-2 2 2 4 2"/>',
  eye: '<path d="M3 12s4-6 9-6 9 6 9 6-4 6-9 6-9-6-9-6z"/><path d="M4 4l16 16"/>',
  film: '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M8 5v14M16 5v14M3 12h18"/>',
  mesh: '<circle cx="12" cy="5" r="2"/><circle cx="5" cy="18" r="2"/><circle cx="19" cy="18" r="2"/><path d="M12 7 6.5 16M12 7l5.5 9M7 18h10"/>',
  sun: '<path d="M12 5v-2M5 12H3M19 12h-2M6.5 6.5 5 5M17.5 6.5 19 5"/><path d="M4 18h16"/><path d="M12 18a5 5 0 0 0-5-5"/><path d="M12 18a5 5 0 0 1 5-5"/>',
  lock: '<rect x="4" y="10" width="16" height="10" rx="2"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/><path d="M12 14v3"/>',
  hour: '<path d="M7 3h10M7 21h10"/><path d="M8 3v4l4 5 4-5V3"/><path d="M8 21v-4l4-5 4 5v4"/>',
  heart: '<rect x="2" y="4" width="20" height="16" rx="3"/><path d="M12 17s-4-2.6-4-5.2A2.2 2.2 0 0 1 12 10a2.2 2.2 0 0 1 4 1.8C16 14.4 12 17 12 17z"/>',
  tv: '<rect x="2" y="7" width="20" height="13" rx="2"/><path d="M8 3l4 4 4-4"/>',
  shield: '<path d="M12 2.6 4.6 5.4v6.1c0 4.4 3 8.2 7.4 9.9 4.4-1.7 7.4-5.5 7.4-9.9V5.4L12 2.6z"/>',
  chev: '<path d="M9 5l7 7-7 7"/>'
};
function svgIcon(name, size) {
  var path = ICONS[name];
  if (!path) { return h("span", { text: "•" }); }
  var wrap = h("span", { "aria-hidden": "true" });
  /* The only innerHTML use in this file: a constant table above, no remote data. */
  wrap.innerHTML = '<svg viewBox="0 0 24 24" width="' + (size || 18) + '" height="' + (size || 18) +
    '" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">' + path + "</svg>";
  return wrap;
}
var SYMBOL_ICON = {
  "brain.head.profile": "brain",
  "water.waves": "waves",
  "eye.slash": "eye",
  "film.stack": "film",
  "point.3.connected.trianglepath.dotted": "mesh",
  "sun.horizon": "sun",
  "lock.shield": "lock",
  "hourglass": "hour",
  "heart.text.square": "heart",
  "play.tv": "tv"
};

/* --------------------------------------------------------------- i18n IO */
/* Fills the picker from `LOCALES`, which is `ConsoleLanguage.displayOrder`
   injected by the node: the 17 regions the POPOPX iOS app ships plus `system`.
   Re-run on every language flip because the option labels are endonyms, which
   by design never translate — a Hungarian always reads "Magyar". */
function buildLangMenu() {
  var select = el("lang-select");
  if (!select) { return; }
  select.innerHTML = "";
  LOCALES.forEach(function (item) {
    var option = document.createElement("option");
    option.value = item.code;
    option.textContent = item.name;
    if (item.code === S.lang) { option.selected = true; }
    select.appendChild(option);
  });
  select.value = S.lang;
}

function applyLang() {
  var catalog = catalogFor(S.lang);
  document.documentElement.setAttribute("data-lang", S.lang);
  document.documentElement.setAttribute("lang",
    catalog === "zh" ? "zh-Hans-CN" : (catalog === "zhHant" ? "zh-Hant-TW" : "en"));
  buildLangMenu();
  var missing = [];
  Array.prototype.forEach.call(document.querySelectorAll("[data-i18n]"), function (node) {
    var key = node.getAttribute("data-i18n");
    var value = catalogValue(key, catalog);
    if (value === null) { missing.push(key); return; }
    node.textContent = value;
  });
  Array.prototype.forEach.call(document.querySelectorAll("[data-i18n-ph]"), function (node) {
    var key = node.getAttribute("data-i18n-ph");
    var value = catalogValue(key, catalog);
    if (value !== null) { node.setAttribute("placeholder", value); }
  });
  /* Accessible names are read aloud by VoiceOver, so they are part of the
     catalog too — an English "Language" in a Chinese console is a bug. */
  Array.prototype.forEach.call(document.querySelectorAll("[data-i18n-aria]"), function (node) {
    var key = node.getAttribute("data-i18n-aria");
    var value = catalogValue(key, catalog);
    if (value !== null) { node.setAttribute("aria-label", value); }
  });
  if (missing.length) {
    /* Loud, visible, and never falls back to the raw key on screen. */
    console.error("missing i18n keys", missing.join(", "));
    toast("warn", "i18n " + missing.length);
  }
  /* Re-run the connection chip through its own setter: the label and the title
     are the only two strings there that are not `[data-i18n]` nodes, and
     `setConn` already null-checks both, so a language flip cannot throw. */
  setConn(CONN.state);
  renderAll();
}

/* ------------------------------------------------------- connection state */
var CONN = { state: "connecting", lastOk: 0, lastPoll: 0 };
var CHANNELS = ["install", "pairing", "engine", "bridge", "result", "mesh", "sentinel", "settings", "system"];

function connKeyFor(state) { return state === "retry" ? "retryState" : state; }
function setConn(state) {
  CONN.state = state;
  var dot = el("dot"), btn = el("conn");
  if (dot) { dot.setAttribute("data-state", state); }
  if (btn) {
    btn.setAttribute("data-state", state);
    btn.setAttribute("title", t(connKeyFor(state)));
    var label = el("conn-text");
    if (label) { label.textContent = t(connKeyFor(state)); }
  }
  show("offline", state === "offline" || state === "retry");
}

function openSSE() {
  if (S.es) { try { S.es.close(); } catch (ignored) { } S.es = null; }
  if (!TOKEN) {
    setConn("offline");
    toast("err", "token");
    return;
  }
  setConn(CONN.lastOk ? "connecting" : "connecting");
  var source = new EventSource(ROUTE.events + "?t=" + encodeURIComponent(TOKEN));
  S.es = source;
  source.onopen = function () {
    S.esBackoff = 1000;
    CONN.lastOk = Date.now();
    setConn("live");
    refreshSnapshot(true);
  };
  source.onerror = function () { scheduleReconnect(); };
  CHANNELS.forEach(function (channel) {
    source.addEventListener(channel, function (event) { onFrame(channel, event.data); });
  });
  source.onmessage = function (event) { onFrame("system", event.data); };
}

/* Exponential backoff. The server advertises `retry: 3000`, but a node that is
   gone must not turn the page into a 1 Hz reconnect loop. */
function scheduleReconnect() {
  if (S.esTimer) { return; }
  if (S.es) { try { S.es.close(); } catch (ignored) { } S.es = null; }
  setConn(CONN.lastOk ? "retry" : "offline");
  var delay = Math.min(30000, S.esBackoff);
  S.esBackoff = Math.min(30000, S.esBackoff * 2);
  S.esTimer = window.setTimeout(function () { S.esTimer = null; openSSE(); }, delay);
}

function onFrame(channel, data) {
  CONN.lastOk = Date.now();
  setConn("live");
  var event = null;
  try { event = JSON.parse(String(data)); } catch (ignored) { event = null; }
  var level = event && event.level ? String(event.level) : "info";
  var message = event && event.message ? String(event.message) : String(data);
  var at = event && event.at ? event.at : null;
  var payload = (event && event.payload) || null;
  if (channel === "install") {
    addLog({
      time: at,
      level: level,
      channel: "install",
      text: message,
      phase: payload && payload.phase ? String(payload.phase) : "",
      seq: payload && payload.seq !== undefined ? Number(payload.seq) : undefined
    });
  }
  if (channel === "pairing") { refreshSnapshot(true); return; }
  queueRefresh();
}

function queueRefresh() {
  if (S.refreshTimer) { window.clearTimeout(S.refreshTimer); }
  S.refreshTimer = window.setTimeout(function () { S.refreshTimer = null; refreshSnapshot(false); }, 140);
}

function refreshSnapshot(force) {
  CONN.lastPoll = Date.now();
  return api(ROUTE.snapshot).then(function (snap) {
    CONN.lastOk = Date.now();
    if (S.es) { setConn("live"); }
    var first = !S.snap;
    S.snap = snap;
    S.clockOffset = new Date(snap.serverTime).getTime() - Date.now();
    if (first) { S.hadTunnel = liveDevices(snap).length > 0; }
    absorbTail(snap);
    if (!S.formBuilt) { buildSettingsForm(snap); }
    /* The node owns the language choice, so the first snapshot after a reload
       wins over the page default; later snapshots must not yank the UI out
       from under someone editing the form or waiting on their own change. */
    if (!S.langAdopted) {
      S.langAdopted = true;
      var saved = (snap.settings || {}).language;
      if (!S.langPending && localeKnown(saved) && saved !== S.lang) { adoptLanguage(saved); }
    }
    renderAll();
  }).catch(function (error) {
    if (!S.snap) { renderFatal(error); }
    setConn(CONN.lastOk ? "offline" : "connecting");
    if (error && error.status === 401) { toast("err", String(error.message)); }
  });
}

/* A reload must still show the installer history: the snapshot carries
   install.tail and the hub replays its backlog, so both are folded in here
   and deduped by sequence number. */
function absorbTail(snap) {
  ((snap.install && snap.install.tail) || []).forEach(function (line) {
    addLog({ time: line.at, level: line.level, channel: "install", phase: line.phase, text: line.text, seq: line.seq });
  });
  (snap.eventsBacklog || []).forEach(function (event) {
    if (event.channel !== "install") { return; }
    addLog({ time: event.at, level: event.level, channel: event.channel, text: event.message, phase: "" });
  });
}

function renderFatal(error) {
  var message = error && error.message ? String(error.message) : String(error);
  ["stats", "gauge", "toolchain", "ladder", "checklist", "pair-body", "devices", "bridge",
    "engines", "mesh", "sentinel", "ark", "drill"].forEach(function (id) {
      var slot = el(id);
      if (!slot) { return; }
      clear(slot);
      slot.appendChild(h("div", { cls: "error" }, [
        h("span", { text: t("loadFailed") }),
        h("span", { cls: "mono", text: message }),
        h("button", { cls: "btn btn--mini", text: t("reloadRetry"), onclick: "PPX.retry()" })
      ]));
    });
  setText("install-badge", t("offline"));
}

/* -------------------------------------------------------------- utilities */
function liveDevices(snap) {
  return ((snap && snap.pairedDevices) || []).filter(function (device) { return !device.revoked; });
}
function runtimeFor(snap, kind) {
  var list = snap.engines || [];
  for (var index = 0; index < list.length; index += 1) {
    if (list[index].kind === kind) { return list[index]; }
  }
  return null;
}
function enabledCount(snap) { return (snap.engines || []).filter(function (item) { return item.enabled; }).length; }
function ollamaReady(snap) {
  var list = snap.toolchain || [];
  for (var index = 0; index < list.length; index += 1) {
    if (String(list[index].name).toLowerCase().indexOf("ollama") >= 0) { return Boolean(list[index].present); }
  }
  return Boolean(snap.install && snap.install.phase === "ready");
}
function ceilingGB() {
  var hardware = S.snap && S.snap.hardware;
  if (!hardware) { return 32; }
  var value = Number(hardware.meshMemoryCeilingGB);
  if (value > 0) { return Math.max(4, Math.round(value)); }
  return Math.max(8, Math.round((Number(hardware.memoryGB) || 16) * 0.55));
}
function phaseKey(phase) {
  var text = String(phase || "idle");
  return "phase" + text.charAt(0).toUpperCase() + text.slice(1);
}
function tierLabel(tier) {
  if (tier === "flagship") { return t("tierCap"); }
  if (tier === "high") { return t("tierQuant"); }
  if (tier === "light") { return t("tierLight"); }
  return t("unknown");
}
function emptyState(key) { return h("div", { cls: "empty" }, h("span", { text: t(key) })); }
function noteLine(key) { return h("p", { cls: "field__note", text: t(key) }); }

/* ------------------------------------------------------------------- log */
function logRank(level) {
  var order = { debug: 0, info: 1, notice: 2, success: 3, warning: 4, error: 5 };
  return order[level] === undefined ? 1 : order[level];
}
function logPasses(entry) { return S.logFilter === "all" ? true : logRank(entry.level) >= logRank(S.logFilter); }
function logNode(entry) {
  var line = h("div", { cls: "line", "data-level": entry.level });
  line.appendChild(h("span", { cls: "line__t", text: clockOf(dateOf(entry.time)) }));
  line.appendChild(h("span", { cls: "line__g", text: LEVEL_GLYPH[entry.level] || "›" }));
  if (entry.phase) { line.appendChild(h("span", { cls: "line__c", text: "[" + entry.phase + "]" })); }
  line.appendChild(h("span", { cls: "line__m", text: String(entry.text) }));
  return line;
}
function seenKey(entry) {
  return entry.seq !== undefined && entry.seq !== null
    ? "seq:" + entry.seq
    : "k:" + entry.channel + ":" + String(entry.time) + ":" + String(entry.text);
}
function addLog(entry) {
  var key = seenKey(entry);
  if (S.seen[key]) { return; }
  S.seen[key] = true;
  S.entries.push(entry);
  if (S.entries.length > LOG_LIMIT) {
    S.entries.splice(0, S.entries.length - LOG_LIMIT);
    if (Object.keys(S.seen).length > LOG_LIMIT * 3) {
      var pruned = {};
      S.entries.forEach(function (kept) { pruned[seenKey(kept)] = true; });
      S.seen = pruned;
    }
  }
  var body = el("log");
  if (!body || S.step !== 1 || !logPasses(entry)) { return; }
  var placeholder = body.querySelector(".empty");
  if (placeholder) { body.removeChild(placeholder); }
  body.appendChild(logNode(entry));
  while (body.children.length > LOG_LIMIT) { body.removeChild(body.firstChild); }
  if (S.autoScroll) { body.scrollTop = body.scrollHeight; }
  setText("logcount", S.entries.length + " " + t("logLines"));
}
function rebuildLog() {
  var body = el("log");
  if (!body) { return; }
  clear(body);
  var shown = 0;
  S.entries.forEach(function (entry) {
    if (!logPasses(entry)) { return; }
    shown += 1;
    body.appendChild(logNode(entry));
  });
  if (!shown) { body.appendChild(emptyState("logEmpty")); }
  if (S.autoScroll) { body.scrollTop = body.scrollHeight; }
  setText("logcount", S.entries.length + " " + t("logLines"));
}
function onLogScroll() {
  var body = el("log");
  if (!body) { return; }
  var gap = body.scrollHeight - body.scrollTop - body.clientHeight;
  S.autoScroll = gap <= 24;
  show("lockbtn", !S.autoScroll);
}

/* ------------------------------------------------------------ top / rail */
function renderTop() {
  var snap = S.snap, node = snap.node || {}, hardware = snap.hardware || {}, install = snap.install || {};
  setText("node-name", node.displayName || "POPOPX Node");
  setText("node-ref", String(node.version || snap.version || "") + " · schema " + String(node.schemaRevision || "?"));
  setText("chip-mem", String(hardware.shortLabel || ((hardware.chipName || "?") + " · " + String(hardware.memoryGB || "?") + " GB")));
  el("chip-mem").setAttribute("title", String(hardware.serialMasked || ""));
  setText("serial-ref", "#" + String(node.nodeId || "").slice(0, 8));
  setText("foot-ref", "node " + String(node.nodeId || "") + " · " + String(snap.consoleURL || ""));
  var badge = el("install-badge");
  badge.textContent = t(phaseKey(install.phase));
  badge.className = "tag " + (install.phase === "ready" ? "tag--ok"
    : install.phase === "failed" ? "tag--bad" : install.running ? "tag--accent" : "tag--off");
}

var RAIL_ICON = { done: "done", run: "run", wait: "wait", todo: "todo" };
function setRail(number, status) {
  var btn = el("rail-" + number);
  if (btn) { btn.setAttribute("data-status", status); }
  var slot = el("railbadge-" + number);
  if (slot) { clear(slot); slot.appendChild(svgIcon(RAIL_ICON[status] || "todo", 16)); }
}
function renderRail() {
  var snap = S.snap, install = snap.install || {}, offer = snap.pairing;
  var devices = liveDevices(snap);
  setRail(1, install.phase === "ready" ? "done" : install.running ? "run" : install.phase === "failed" ? "wait" : "todo");
  setRail(2, devices.length ? "done"
    : !offer ? "run"
      : new Date(offer.expiresAt).getTime() < nodeNow() ? "wait" : "todo");
  setRail(3, enabledCount(snap) > 0 ? "done" : "todo");
  // Step four's badge is the one that should pull an operator back to the page: a
  // proposal is only actionable while its receipt is alive.
  var privacy = snap.privacy || {};
  setRail(4, pvPendingCards().length ? "wait"
    : (privacy.calendarAllowed || privacy.workspaceReadAllowed || privacy.workspaceWriteAllowed) ? "done" : "todo");
  // Step five reads the switches from the saved document, and the *reachability* from the
  // last `/v1/tools/*/status` fetch (`S.hub`). A switch that has no target behind it is off
  // inside the engine even while it is ticked here, which is exactly what the panel's own
  // 「被拒绝 / refused」 rows say, so the badge is allowed to be optimistic and the rows are not.
  setRail(5, hvPendingCards().length ? "wait" : hvAnyOn() ? "done" : "todo");
}

/* -------------------------------------------------------------- step one */
function statCard(key, value, note, small) {
  return h("div", { cls: "stat" }, [
    h("span", { cls: "stat__k", text: t(key) }),
    h("span", { cls: "stat__v" + (small ? " stat__v--sm" : ""), text: value }),
    note ? h("span", { cls: "stat__n", text: note }) : null
  ]);
}
function renderStats() {
  var snap = S.snap, hardware = snap.hardware || {}, load = snap.load || {}, plan = snap.plan || {};
  var slot = el("stats");
  clear(slot);
  slot.appendChild(statCard("chip", String(hardware.chipName || t("unknown")), String(hardware.modelIdentifier || ""), true));
  slot.appendChild(statCard("cores",
    String(hardware.performanceCoreCount || 0) + "P · " + String(hardware.efficiencyCoreCount || 0) + "E",
    t("coresNote") + " · " + String(hardware.logicalCPUCount || 0)));
  slot.appendChild(statCard("mem", String(hardware.memoryGB || 0) + " GB", bytes(hardware.memoryTotal && hardware.memoryTotal.bytes), true));
  slot.appendChild(statCard("freeDisk", bytes(hardware.freeDisk && hardware.freeDisk.bytes),
    t("freeDiskNote") + " " + bytes(hardware.totalDisk && hardware.totalDisk.bytes)));
  slot.appendChild(statCard("tier", tierLabel(hardware.tier || plan.tier), String(plan.videoPrecision || ""), true));
  slot.appendChild(statCard("cpu", fmt(load.cpuLoadPercent, 0) + " %",
    t("processes") + " " + String(load.activeProcessCount || 0) + " · " + t("pressure") + " " + t(String(load.memoryPressure || "nominal"))));
}

var SVG_NS = "http://www.w3.org/2000/svg";
function svgShape(name, attrs) {
  var node = document.createElementNS(SVG_NS, name);
  Object.keys(attrs || {}).forEach(function (key) { node.setAttribute(key, String(attrs[key])); });
  return node;
}
function buildGauge() {
  var slot = el("gauge");
  clear(slot);
  var svg = svgShape("svg", { viewBox: "0 0 120 120", role: "img", "aria-label": t("memTitle") });
  var innerArc = svgShape("circle", {
    class: "gauge__ring gauge__arc", cx: 60, cy: 60, r: 42,
    "stroke-dasharray": 263.9, "stroke-dashoffset": 263.9, transform: "rotate(-90 60 60)"
  });
  var outerArc = svgShape("circle", {
    class: "gauge__ring gauge__arc--outer", cx: 60, cy: 60, r: 54,
    "stroke-dasharray": 339.3, "stroke-dashoffset": 339.3, transform: "rotate(-90 60 60)"
  });
  [svgShape("circle", { class: "gauge__ring gauge__bg", cx: 60, cy: 60, r: 54 }),
    outerArc,
    svgShape("circle", { class: "gauge__ring gauge__bg", cx: 60, cy: 60, r: 42 }),
    innerArc].forEach(function (node) { svg.appendChild(node); });
  slot.appendChild(h("div", { cls: "gauge" }, [
    svg,
    h("div", { cls: "gauge__label" }, [
      h("span", { cls: "gauge__pct", id: "gauge-pct" }, "0%"),
      h("span", { cls: "gauge__cap", id: "gauge-cap" }, t("loadingShort")),
      h("span", { cls: "gauge__val", id: "gauge-val" }, "")
    ])
  ]));
  S.gauge = { inner: innerArc, outer: outerArc };
}
function renderGauge() {
  var snap = S.snap, hardware = snap.hardware || {}, load = snap.load || {}, plan = snap.plan || {};
  if (!S.gauge || !el("gauge-pct")) { buildGauge(); }
  var total = Number(hardware.memoryTotal && hardware.memoryTotal.bytes) || 1;
  var used = Number(load.memoryUsed && load.memoryUsed.bytes) || 0;
  var share = Math.max(0, Math.min(1, used / total));
  var resident = Math.max(0, Math.min(1, (Number(plan.expectedResidentGB) || 0) / (Number(hardware.memoryGB) || 1)));
  S.gauge.inner.setAttribute("stroke-dashoffset", String(263.9 * (1 - share)));
  S.gauge.outer.setAttribute("stroke-dashoffset", String(339.3 * (1 - resident)));
  setText("gauge-pct", Math.round(share * 100) + "%");
  setText("gauge-cap", t("usedOf") + " " + bytes(total));
  setText("gauge-val", bytes(used) + " · " + t("thResident") + " " + String(plan.expectedResidentGB || 0) + " GB");
}
function renderToolchain() {
  var list = (S.snap && S.snap.toolchain) || [];
  var slot = el("toolchain");
  clear(slot);
  if (!list.length) { slot.appendChild(emptyState("toolchainEmpty")); return; }
  list.forEach(function (probe) {
    var pill = h("span", { cls: "pill" + (probe.present ? "" : " is-missing"), title: anon(probe.resolvedPath || "") });
    pill.appendChild(h("span", { cls: "pill__led" }));
    pill.appendChild(h("span", { text: String(probe.name || "?") }));
    if (probe.versionLine) { pill.appendChild(h("span", { cls: "pill__ver", text: String(probe.versionLine).slice(0, 34) })); }
    pill.appendChild(h("span", { cls: "tag " + (probe.present ? "tag--ok" : "tag--bad"), text: probe.present ? t("present") : t("missing") }));
    slot.appendChild(pill);
  });
}
var LADDER = [
  { tier: "flagship", band: ">= 96 GB", llm: "qwen3.8:27b-q8_0", video: "ltx-2.5 · BF16", policy: "heavyLocal" },
  { tier: "high", band: "48 - 95 GB", llm: "qwen3.8:27b-q4_k_m", video: "ltx-2.5-mlx-8bit", policy: "heavyLocal" },
  { tier: "light", band: "< 48 GB", llm: "qwen3.8:9b-q4_k_m", video: "ltx-2.5-mlx-4bit", policy: "heavyMesh" }
];
function renderLadder() {
  var snap = S.snap, plan = snap.plan || {}, hardware = snap.hardware || {};
  var slot = el("ladder");
  clear(slot);
  var head = document.createElement("tr");
  ["thBand", "thLLM", "thVideo", "thResident", "thNote"].forEach(function (key) { head.appendChild(h("th", { text: t(key) })); });
  var thead = document.createElement("thead");
  thead.appendChild(head);
  slot.appendChild(thead);
  var body = document.createElement("tbody");
  LADDER.forEach(function (row) {
    var active = String(plan.tier || hardware.tier || "") === row.tier;
    var tr = document.createElement("tr");
    if (active) { tr.className = "is-active"; }
    tr.appendChild(h("td", { cls: "cell-strong", text: row.band }));
    tr.appendChild(h("td", { text: active ? String(plan.llmRef || row.llm) + " · " + String(plan.llmQuantization || "") : row.llm }));
    tr.appendChild(h("td", { text: active ? String(plan.videoRef || "") + " · " + String(plan.videoPrecision || "") : row.video }));
    tr.appendChild(h("td", { text: active ? String(plan.expectedResidentGB || 0) + " GB" : "—" }));
    var policy = active ? (plan.routeHeavyVideoToMesh ? "heavyMesh" : "heavyLocal") : row.policy;
    tr.appendChild(h("td", {}, h("span", { cls: "tag " + (policy === "heavyMesh" ? "tag--warn" : "tag--ok"), text: t(policy) })));
    body.appendChild(tr);
  });
  slot.appendChild(body);
  setText("plan-llm", String(plan.llmRef || "—"));
  setText("plan-note", plan.rationale ? t("planNote") + " · " + String(plan.rationale) : t("noPlan"));
  if (plan.ollamaModelPull) { S.copyable.pull = String(plan.ollamaModelPull); }
  renderModelPicker();
}
function modelById(id) {
  var list = (MODELS && MODELS.models) || [];
  for (var index = 0; index < list.length; index += 1) { if (list[index].id === id) { return list[index]; } }
  return null;
}
/// Matches a reference the node resolved, which may carry a tag the catalog does
/// not know (`inkling-2-mini:q4_k_m` from `config/model_refs.json`), so the base
/// model name is the fallback key.
function modelByRef(ref) {
  var list = (MODELS && MODELS.models) || [];
  var base = String(ref || "").split(":")[0];
  for (var index = 0; index < list.length; index += 1) {
    if (list[index].ref === ref || String(list[index].ref).split(":")[0] === base) { return list[index]; }
  }
  return null;
}
function admissionKey(model, memoryGB) {
  if (memoryGB >= model.co) { return "coResident"; }
  if (memoryGB >= model.rec) { return "recommended"; }
  if (memoryGB > model.swap) { return "constrained"; }
  return "swapWarning";
}
function admissionLabel(key) {
  var list = (MODELS && MODELS.admission) || [];
  var field = { zh: "zh", zhHant: "hant" }[catalogFor(S.lang)] || "en";
  for (var index = 0; index < list.length; index += 1) {
    if (list[index].key === key) { return String(list[index][field] || list[index].en || key); }
  }
  return key;
}
function renderModelPicker() {
  var select = el("model-select");
  if (!select) { return; }
  var snap = S.snap, plan = snap.plan || {}, hardware = snap.hardware || {}, settings = snap.settings || {};
  var memoryGB = Number(hardware.memoryGB) || 0;
  var pinned = String(settings.llmModelOverride || "");
  var list = (MODELS && MODELS.models) || [];
  clear(select);
  select.appendChild(h("option", { value: "", text: t("modelDefault") + (pinned ? "" : "  ·  " + String(plan.llmRef || "")) }));
  list.forEach(function (model) {
    var label = model.name + " · " + model.quant + " · ~" + (Number(model.weight) + Number(model.ctx)) + " GB";
    select.appendChild(h("option", { value: String(model.id), text: label }));
  });
  // The pin is normally an id, but an owner who edited settings.json by hand may
  // have written the tagged reference instead, so both forms select the row.
  select.value = (modelById(pinned) || modelByRef(pinned) || {}).id || "";
  var live = el("model-live");
  var active = modelByRef(plan.llmRef);
  clear(live);
  if (!memoryGB) { setText("model-note", t("noPlan")); el("model-copy").hidden = true; return; }
  if (!active) {
    // A pin the catalog does not know. The node still runs it, so the pull command
    // stays copyable and the note says plainly that no estimate exists for it.
    if (pinned) { live.appendChild(h("span", { cls: "tag tag--accent", text: t("modelPinnedNote") })); }
    setText("model-note", t("modelUnknown"));
    S.modelPull = String(plan.ollamaModelPull || "");
    var ghost = el("model-copy");
    ghost.hidden = !S.modelPull;
    ghost.textContent = t("modelCopyPull");
    return;
  }
  var verdict = admissionKey(active, memoryGB);
  var tagClass = verdict === "swapWarning" ? "tag--bad" : (verdict === "constrained" ? "tag--warn" : "tag--ok");
  live.appendChild(h("span", { cls: "tag " + tagClass, text: t("modelAdmission") + " · " + admissionLabel(verdict) }));
  live.appendChild(h("span", { cls: "tag", text: t("modelResident") + " · " + active.weight + " + " + active.ctx + " ≈ " + (Number(active.weight) + Number(active.ctx)) + " GB" }));
  if (pinned) { live.appendChild(h("span", { cls: "tag tag--accent", text: t("modelPinnedNote") })); }
  var note = snapshotField(active, "note");
  if (verdict === "swapWarning") { note = note + " · " + t("modelSwapWarn"); }
  if (active.hint) { note = note + " · " + t("modelGguf") + " " + active.hint; }
  setText("model-note", note);
  S.modelPull = String(plan.ollamaModelPull || active.pull || "");
  var copy = el("model-copy");
  copy.hidden = false;
  copy.textContent = t("modelCopyPull");
}
var STATE_ICON = { pending: "todo", running: "run", done: "done", skipped: "todo", failed: "wait" };
function renderChecklist() {
  var install = (S.snap && S.snap.install) || {};
  var steps = install.steps || [];
  var slot = el("checklist");
  clear(slot);
  if (!steps.length) { slot.appendChild(emptyState("stepsEmpty")); return; }
  steps.forEach(function (step) {
    var state = String(step.state || "pending");
    var li = h("li", { "data-state": state });
    li.appendChild(h("span", { cls: "checklist__ico" }, svgIcon(STATE_ICON[state] || "todo", 18)));
    var text = h("div", { cls: "checklist__body" });
    text.appendChild(h("span", { cls: "checklist__title", text: snapshotField(step, "title") || step.id }));
    if (step.detail) { text.appendChild(h("span", { cls: "checklist__detail", text: String(step.detail) })); }
    if (state === "running") {
      var bar = h("div", { cls: "checklist__bar" });
      var fill = h("i");
      fill.style.width = Math.round(Math.max(0, Math.min(1, Number(step.progress) || 0)) * 100) + "%";
      bar.appendChild(fill);
      text.appendChild(bar);
    }
    li.appendChild(text);
    slot.appendChild(li);
  });
}
function renderDeployControls() {
  var install = (S.snap && S.snap.install) || {};
  var running = Boolean(install.running);
  el("btn-deploy").hidden = running;
  show("btn-cancel", running);
  var text;
  if (running) {
    text = t("installing") + " · " + Math.round(Math.max(0, Math.min(1, Number(install.progress) || 0)) * 100) + "%";
  } else if (install.phase === "ready") {
    text = t("installDone");
  } else if (install.phase === "failed") {
    text = t("installFailedWhy") + " · " + String(install.lastError || t("unknown"));
  } else if (install.phase === "cancelled") {
    text = t("phaseCancelled") + " · " + t("idleHint");
  } else {
    text = t("idleHint");
  }
  setText("deploy-hint", text);
  var logSlot = el("log");
  if (logSlot && !logSlot.firstChild) { logSlot.appendChild(emptyState("logEmpty")); }
}

/* -------------------------------------------------------------- step two */
var PAIR_VIEW = { name: "", code: "" };
function renderPairing() {
  var snap = S.snap;
  var slot = el("pair-body");
  var root = el("pair-root");
  var offer = snap.pairing;
  var devices = liveDevices(snap);
  var badge = el("pair-badge");
  if (devices.length) {
    if (!root.classList.contains("is-done")) {
      root.classList.add("is-done");
    }
    S.hadTunnel = true;
    badge.className = "tag tag--ok";
    badge.textContent = t("paired");
    if (offer && offer.nodePublicKey) { S.copyable.pubkey = String(offer.nodePublicKey); }
    if (PAIR_VIEW.name !== "done") {
      clear(slot);
      renderPairingDiag(offer);
      var first = devices[0];
      slot.appendChild(h("div", { cls: "pair-success" }, [
        h("div", { cls: "pair-success__title" }, [svgIcon("done", 20), h("span", { text: t("tunnel") })]),
        h("p", { cls: "dim", text: t("tunnelSub") }),
        h("div", { cls: "chip mono" }, String(first.label || t("unknown")) + " · " + String(first.publicKey || "").slice(0, 22) + "…"),
        h("div", { cls: "btn-row" }, [
          h("button", { cls: "btn", text: t("rotate"), onclick: "PPX.rotatePairing()" }),
          offer && offer.nodePublicKey ? h("button", { cls: "btn btn--ghost", text: t("copyPubkey"), onclick: "PPX.copyThis('pubkey')" }) : null
        ])
      ]));
      PAIR_VIEW.name = "done";
    }
    return;
  }
  S.hadTunnel = false;
  root.classList.remove("is-done");
  if (!offer) {
    badge.className = "tag tag--off";
    badge.textContent = t("daemonStarting");
    if (PAIR_VIEW.name !== "none") {
      clear(slot);
      PAIR_VIEW.name = "none";
      PAIR_VIEW.code = "";
      renderPairingDiag(null);
      slot.appendChild(h("div", { cls: "stack" }, [
        emptyState("noPairing"),
        h("button", { cls: "btn", text: t("rotate"), onclick: "PPX.rotatePairing()" })
      ]));
    }
    return;
  }
  S.copyable.pubkey = String(offer.nodePublicKey || "");
  var expired = new Date(offer.expiresAt).getTime() < nodeNow();
  badge.className = "tag " + (offer.used ? "tag--accent" : expired ? "tag--bad" : "tag--ok");
  badge.textContent = offer.used ? t("used") : expired ? t("expired") : t("oneTime");
  var code = String(offer.code || "");
  if (PAIR_VIEW.name !== "qr" || PAIR_VIEW.code !== code) {
    clear(slot);
    PAIR_VIEW.name = "qr";
    PAIR_VIEW.code = code;
    var image = document.createElement("img");
    image.id = "qr-img";
    image.setAttribute("alt", t("qr"));
    image.addEventListener("error", function () { renderQRFallback(); });
    slot.appendChild(h("div", { cls: "qr-box" }, h("div", { cls: "qr-wrap", id: "qr-slot" }, [
      image,
      h("span", { cls: "mute", id: "qr-state", text: t("qrLoading") })
    ])));
    slot.appendChild(h("div", { cls: "btn-row" }, [
      h("span", { cls: "countdown", id: "pair-countdown", text: "" }),
      h("button", { cls: "btn btn--mini", text: t("copyLink"), onclick: "PPX.copyThis('link')" })
    ]));
    slot.appendChild(h("div", { cls: "stack" }, [
      valueBlock("link", offer.pairingLink),
      h("p", { cls: "field__note", text: t("pairLinkNote") }),
      h("p", {
        cls: "field__note",
        text: t("expiry") + " · " + stampOf(dateOf(offer.issuedAt)) + " → " + stampOf(dateOf(offer.expiresAt)) +
          " · " + (offer.oneTime ? t("oneTime") : "")
      }),
      h("button", { cls: "btn btn--primary", text: t("rotate"), onclick: "PPX.rotatePairing()" })
    ]));
    renderPairingDiag(offer);
    loadQR(code);
  }
  updatePairCountdown();
}
/* The raw credential belongs to the developer drawer and nowhere else on the page:
   the signed code and the daemon link both carry the signalling queue address, and
   the drawer body stays hidden until the owner opens it. */
function renderPairingDiag(offer) {
  var host = el("pair-diag");
  if (!host) { return; }
  clear(host);
  if (!offer) {
    S.copyable.code = "";
    S.copyable.uri = "";
    S.copyable.link = "";
    host.appendChild(h("p", { cls: "field__note", text: t("pairDiagEmpty") }));
    return;
  }
  S.copyable.code = String(offer.code || "");
  S.copyable.uri = String(offer.invitationURI || "");
  S.copyable.pubkey = String(offer.nodePublicKey || "");
  S.copyable.link = String(offer.pairingLink || "");
  host.appendChild(valueBlock("code", offer.code));
  host.appendChild(valueBlock("uri", offer.invitationURI));
  host.appendChild(valueBlock("pubkey", offer.nodePublicKey));
}
function loadQR(code) {
  var image = el("qr-img");
  if (!image) { return; }
  var params = new URLSearchParams();
  params.set("t", TOKEN);
  params.set("size", "512");
  params.set("v", hashKey(code));
  image.addEventListener("load", function () {
    var state = el("qr-state");
    if (state) { state.textContent = t("qr"); }
  });
  image.src = ROUTE.pairingQR + "?" + params.toString();
}
function renderQRFallback() {
  var slot = el("qr-slot");
  if (!slot) { return; }
  clear(slot);
  slot.appendChild(h("div", { cls: "error" }, [
    h("span", { text: t("qrLoadFailed") }),
    h("span", { text: t("noQR") }),
    h("button", { cls: "btn btn--mini", text: t("qrRetry"), onclick: "PPX.qrRetry()" })
  ]));
}
function valueBlock(name, value) {
  var labelKey = name === "link" ? "pairLink" : name === "code" ? "code" : name === "uri" ? "uri" : "pubkey";
  var buttonKey = name === "link" ? "copyLink" : name === "code" ? "copyCode" : name === "uri" ? "copyURI" : "copyPubkey";
  return h("div", { cls: "stack" }, [
    h("span", { cls: "field__label", text: t(labelKey) }),
    h("div", { cls: "code", text: String(value || "—") }),
    h("button", { cls: "btn btn--mini", text: t(buttonKey), onclick: "PPX.copyThis('" + name + "')" })
  ]);
}
function updatePairCountdown() {
  if (!S.snap || S.step !== 2 || PAIR_VIEW.name !== "qr") { return; }
  var offer = S.snap.pairing;
  var node = el("pair-countdown");
  if (!offer || !node) { return; }
  var remaining = Math.round((new Date(offer.expiresAt).getTime() - nodeNow()) / 1000);
  if (remaining <= 0) {
    node.textContent = t("expired");
    node.classList.add("is-out");
    if (PAIR_VIEW.name === "qr" && !S.expiredRendered) { S.expiredRendered = true; renderPairing(); }
    return;
  }
  S.expiredRendered = false;
  node.classList.remove("is-out");
  node.textContent = t("expiry") + " " + zero2(Math.floor(remaining / 60)) + ":" + zero2(remaining % 60);
}
function renderDevices() {
  var devices = (S.snap && S.snap.pairedDevices) || [];
  var slot = el("devices");
  clear(slot);
  setText("devices-count", String(devices.filter(function (item) { return !item.revoked; }).length));
  if (!devices.length) { slot.appendChild(emptyState("devicesEmpty")); return; }
  var table = h("table", { cls: "table table--rows" });
  var head = document.createElement("tr");
  ["devices", "pairedAt", "lastSeen", "revoke"].forEach(function (key) { head.appendChild(h("th", { text: t(key) })); });
  var thead = document.createElement("thead");
  thead.appendChild(head);
  table.appendChild(thead);
  var body = document.createElement("tbody");
  devices.forEach(function (device) {
    var row = document.createElement("tr");
    row.appendChild(h("td", {}, [
      h("div", { cls: "cell-strong", text: String(device.label || t("unknown")) }),
      h("div", { cls: "mono mute", text: String(device.publicKey || "").slice(0, 26) + "…" }),
      device.deviceModel ? h("div", { cls: "mute", text: String(device.deviceModel) }) : null
    ]));
    row.appendChild(h("td", { text: stampOf(dateOf(device.pairedAt)) + " · " + relTime(dateOf(device.pairedAt)) }));
    row.appendChild(h("td", { text: device.lastSeenAt ? relTime(dateOf(device.lastSeenAt)) : t("neverSeen") }));
    row.appendChild(h("td", {}, device.revoked
      ? h("span", { cls: "tag tag--bad", text: t("revokedRow") })
      : h("button", { cls: "btn btn--mini", text: t("revoke"), "data-key": String(device.publicKey || ""), onclick: "PPX.revokeDevice(this)" })));
    body.appendChild(row);
  });
  table.appendChild(body);
  slot.appendChild(table);
}
function renderBridge() {
  var bridge = (S.snap && S.snap.bridge) || {};
  var keys = {
    stopped: "daemonStopped", starting: "daemonStarting", running: "daemonRunning",
    degraded: "daemonDegraded", missingBinary: "daemonMissing"
  };
  var tag = el("daemon-tag");
  tag.textContent = t(keys[String(bridge.daemon || "stopped")] || "daemonStopped");
  tag.className = "tag " + (bridge.daemon === "running" ? "tag--ok" : bridge.daemon === "degraded" ? "tag--warn" : "tag--bad");
  var slot = el("bridge");
  clear(slot);
  slot.appendChild(statCard("wsOn", bridge.websocketConnected ? t("yes") : t("no"), t(bridge.websocketConnected ? "wsOn" : "wsOff"), true));
  slot.appendChild(statCard("accepted", String(bridge.acceptedCommands || 0), t("rejected") + " " + String(bridge.rejectedCommands || 0)));
  slot.appendChild(statCard("delivered", String(bridge.deliveredResults || 0), t("outbox") + " " + String(bridge.outboxDepth || 0)));
  slot.appendChild(statCard("uptime", dur(bridge.uptimeSeconds), "port " + String(bridge.controlPort || ""), true));
  setText("bridge-binary", bridge.binaryPath
    ? t("daemonPath") + " · " + anon(String(bridge.binaryPath)) + (bridge.lastError ? " · " + t("bridgeErr") + " · " + String(bridge.lastError) : "")
    : bridge.lastError ? t("bridgeErr") + " · " + String(bridge.lastError) : "");
  setText("bridge-install", bridge.binaryPath ? "" : t("daemonInstall"));
}

/* ------------------------------------------------------------- step three */
function renderEngines() {
  var snap = S.snap;
  var slot = el("engines");
  var descriptors = (snap.descriptors || []).slice().sort(function (a, b) { return (a.order || 0) - (b.order || 0); });
  var badge = el("engines-badge");
  badge.textContent = enabledCount(snap) + " / " + (descriptors.length || 10) + " " + t("enginesBadge");
  badge.className = "tag " + (enabledCount(snap) ? "tag--ok" : "tag--off");
  if (!descriptors.length) {
    clear(slot);
    slot.appendChild(emptyState("enginesLoading"));
    S.engineKeys = "";
    return;
  }
  var signature = descriptors.map(function (item) { return item.kind; }).join(",") + "|" + S.lang;
  if (signature === S.engineKeys && S.engineRows.length === descriptors.length) {
    descriptors.forEach(function (descriptor, index) {
      updateEngineRow(S.engineRows[index], descriptor, runtimeFor(snap, descriptor.kind), snap);
    });
    return;
  }
  clear(slot);
  S.engineRows = [];
  descriptors.forEach(function (descriptor) {
    var row = buildEngineRow(descriptor);
    S.engineRows.push(row);
    slot.appendChild(row.root);
    updateEngineRow(row, descriptor, runtimeFor(snap, descriptor.kind), snap);
  });
  S.engineKeys = signature;
}
function buildEngineRow(descriptor) {
  var toggle = h("button", {
    cls: "switch", role: "switch", tabindex: "0", "aria-checked": "false",
    "data-kind": String(descriptor.kind || ""), onclick: "PPX.toggleEngine(this)"
  }, h("span", { cls: "switch__knob" }));
  toggle.addEventListener("keydown", function (event) {
    if (event.key === "Enter" || event.key === " ") { event.preventDefault(); toggle.click(); }
  });
  var icon = h("span", { cls: "engine__ico" });
  var name = h("span", { cls: "engine__name" });
  var alt = h("span", { cls: "engine__alt" });
  var tagline = h("span", { cls: "engine__tag" });
  var counters = h("div", { cls: "engine__meta" });
  var extras = h("div", { cls: "engine__foot" });
  var root = h("article", { cls: "engine" }, [
    h("div", { cls: "engine__top" }, [icon, h("div", { cls: "engine__id" }, [name, alt, tagline])]),
    counters,
    extras,
    h("div", { cls: "engine__foot" }, [toggle, h("span", { cls: "engine__ref", text: String(descriptor.kind || "") })])
  ]);
  return {
    root: root, icon: icon, name: name, alt: alt, tagline: tagline,
    counters: counters, extras: extras, toggle: toggle, kind: String(descriptor.kind || "")
  };
}
function updateEngineRow(row, descriptor, runtime, snap) {
  var state = runtime || {
    enabled: false, busy: false, runs: 0, failures: 0,
    artifactsProduced: 0, lastRunAt: null, lastSummary: null, lastDurationMs: null
  };
  clear(row.icon);
  row.icon.appendChild(svgIcon(SYMBOL_ICON[String(descriptor.symbolName)] || "shield", 30));
  row.name.textContent = snapshotField(descriptor, "title") || String(descriptor.kind || "");
  row.alt.textContent = uiIsChinese() ? String(descriptor.titleEn || "") : String(descriptor.titleZh || "");
  row.tagline.textContent = snapshotField(descriptor, "tagline");
  row.toggle.setAttribute("aria-checked", state.enabled ? "true" : "false");
  row.toggle.setAttribute("aria-label", row.name.textContent);
  row.root.classList.toggle("is-on", Boolean(state.enabled));
  row.root.classList.toggle("is-busy", Boolean(state.busy));
  clear(row.counters);
  [
    [t("runs"), String(state.runs || 0)],
    [t("failures"), String(state.failures || 0)],
    [t("artifacts"), String(state.artifactsProduced || 0)],
    [t("lastRun"), state.lastRunAt ? stampOf(dateOf(state.lastRunAt)) : t("never")],
    [state.busy ? t("busyNow") : t("idleNow"), state.lastDurationMs ? fmt(state.lastDurationMs, 0) + " ms" : ""]
  ].forEach(function (pair) {
    if (pair[1] === "") { return; }
    row.counters.appendChild(h("span", {}, [pair[0] + " ", h("i", { text: pair[1] })]));
  });
  clear(row.extras);
  (descriptor.requires || []).forEach(function (item) {
    row.extras.appendChild(h("span", { cls: "tag", text: t("requires") + " " + String(item) }));
  });
  if (descriptor.deterministic) { row.extras.appendChild(h("span", { cls: "tag tag--accent", text: t("deterministicFlag") })); }
  var needsModels = (descriptor.requires || []).some(function (item) { return String(item).indexOf("ollama") >= 0; });
  if (needsModels && !ollamaReady(snap)) { row.extras.appendChild(h("span", { cls: "tag tag--warn", text: t("needsModels") })); }
  if (state.lastSummary) { row.extras.appendChild(h("span", { cls: "mute", text: String(state.lastSummary).slice(0, 80) })); }
}

/* ------------------------------------------------------- settings document */
function ensureForm(snap) {
  if (!S.form) {
    S.form = clone(snap.settings || {});
    S.formBase = (snap.settings || {}).revision || 0;
  }
  if (!S.formBuilt) { buildSettingsForm(); S.formBuilt = true; }
}
function markDirty() { S.dirty = true; renderSaveBar(); }
function adoptLanguage(code) {
  var known = localeKnown(code);
  var next = known ? String(code) : "en";
  if (S.lang && S.lang !== "system" && !known) { next = S.lang; }
  S.lang = next;
  S.langPending = false;
  var select = el("lang-select");
  if (select) { select.value = next; }
  document.documentElement.setAttribute("lang", next);
  applyLang();
}
function nodeRevision() { return S.snap && S.snap.settings ? Number(S.snap.settings.revision) : Number(S.formBase) || 0; }
function fieldWrap(labelKey, control, noteNode) {
  return h("label", { cls: "field" }, [
    h("span", { cls: "field__label", text: t(labelKey) }),
    control,
    noteNode || null
  ]);
}
function note(text) { return h("span", { cls: "field__note", text: text }); }
function numField(labelKey, read, write, min, max, noteText, onAfter) {
  var input = h("input", { type: "number", min: String(min), max: String(max), step: "1", value: String(read()) });
  var holder = note(noteText === null || noteText === undefined ? "" : noteText);
  input.addEventListener("input", function () {
    var raw = Number(input.value);
    if (isNaN(raw)) { return; }
    var value = Math.max(min, Math.min(max, Math.round(raw)));
    write(value);
    if (onAfter) { holder.textContent = onAfter(value); }
    markDirty();
  });
  return fieldWrap(labelKey, input, noteText === null ? null : holder);
}
function textField(labelKey, read, write, placeholderKey, noteText) {
  var input = h("input", { type: "text", spellcheck: "false", value: String(read() === undefined || read() === null ? "" : read()) });
  if (placeholderKey) { input.setAttribute("placeholder", t(placeholderKey)); }
  input.addEventListener("input", function () { write(input.value); markDirty(); });
  return fieldWrap(labelKey, input, noteText ? note(t(noteText)) : null);
}
function urlField(labelKey, read, write, placeholder, noteText) {
  var input = h("input", { type: "text", spellcheck: "false", value: String(read() || ""), inputmode: "url" });
  if (placeholder) { input.setAttribute("placeholder", placeholder); }
  input.addEventListener("input", function () { write(input.value); markDirty(); });
  return fieldWrap(labelKey, input, noteText ? note(t(noteText)) : null);
}
function secretField(labelKey, read, write) {
  var input = h("input", { type: "password", spellcheck: "false", value: String(read() || ""), autocomplete: "off" });
  input.addEventListener("input", function () { write(input.value); markDirty(); });
  var button = h("button", { cls: "btn btn--tiny", text: t("secretShow"), type: "button" });
  button.addEventListener("click", function () {
    if (input.type === "password") { input.type = "text"; button.textContent = t("secretHide"); }
    else { input.type = "password"; button.textContent = t("secretShow"); }
  });
  return fieldWrap(labelKey, h("div", { cls: "list__row" }, [input, button]), null);
}
function checkField(labelKey, read, write) {
  var input = h("input", { type: "checkbox" });
  input.checked = Boolean(read());
  input.addEventListener("change", function () { write(input.checked); markDirty(); });
  return h("label", { cls: "check" }, [input, h("span", { text: t(labelKey) })]);
}
function hourSelect(value, write) {
  var select = h("select");
  for (var hour = 0; hour < 24; hour += 1) {
    var option = h("option", { value: String(hour), text: zero2(hour) + ":00" });
    if (hour === Number(value)) { option.selected = true; }
    select.appendChild(option);
  }
  select.addEventListener("change", function () { write(Number(select.value)); markDirty(); });
  return select;
}
function weekdayPicker(item) {
  var host = h("div", { cls: "weekdays" });
  [1, 2, 3, 4, 5, 6, 0].forEach(function (day) {
    var labels = WEEKDAYS[catalogFor(S.lang)] || WEEKDAYS.en;
    var button = h("button", { type: "button", text: labels[day], title: labels[day] });
    button.classList.toggle("is-on", (item.weekdays || []).indexOf(day) >= 0);
    button.addEventListener("click", function () {
      var list = (item.weekdays || []).slice();
      var position = list.indexOf(day);
      if (position >= 0) { list.splice(position, 1); } else { list.push(day); }
      list.sort(function (a, b) { return a - b; });
      item.weekdays = list;
      button.classList.toggle("is-on", list.indexOf(day) >= 0);
      markDirty();
    });
    host.appendChild(button);
  });
  return host;
}
function buildMeshForm() {
  var slot = el("mesh");
  clear(slot);
  var mesh = S.form.mesh = S.form.mesh || {};
  slot.appendChild(checkField("shareEnable", function () { return mesh.sharingEnabled; }, function (value) { mesh.sharingEnabled = value; }));
  slot.appendChild(h("hr", { cls: "hair" }));
  var ceiling = ceilingGB();
  var grid = h("div", { cls: "fields" });
  grid.appendChild(numField("maxMem", function () { return mesh.maxMemoryGB || 8; }, function (value) { mesh.maxMemoryGB = value; },
    4, ceiling, t("maxMemHint") + " " + ceiling + " GB"));
  grid.appendChild(numField("maxJobs", function () { return mesh.maxConcurrentJobs || 1; }, function (value) { mesh.maxConcurrentJobs = value; }, 1, 8, null));
  grid.appendChild(numField("minFree", function () { return mesh.minFreeDiskGB || 10; }, function (value) { mesh.minFreeDiskGB = value; }, 10, 4096, null));
  slot.appendChild(grid);
  slot.appendChild(checkField("ownerPresent", function () { return mesh.requireOwnerPresent; }, function (value) { mesh.requireOwnerPresent = value; }));
  slot.appendChild(h("hr", { cls: "hair" }));
  slot.appendChild(h("span", { cls: "field__label", text: t("windows") }));
  slot.appendChild(h("div", { id: "windows-list", cls: "list" }));
  renderWindowList();
  slot.appendChild(h("button", { cls: "btn btn--mini", text: t("windowAdd"), type: "button", onclick: "PPX.windowAdd()" }));
  slot.appendChild(h("div", { id: "mesh-live", cls: "stack" }));
}
function renderWindowList() {
  var host = el("windows-list");
  if (!host) { return; }
  clear(host);
  var mesh = S.form.mesh;
  mesh.idleWindows = mesh.idleWindows || [];
  mesh.idleWindows.forEach(function (item, index) {
    host.appendChild(h("div", { cls: "list__row" }, [
      hourSelect(item.startHour, function (value) { item.startHour = value; }),
      h("span", { cls: "mute", text: "→" }),
      hourSelect(item.endHour, function (value) { item.endHour = value; }),
      weekdayPicker(item),
      h("button", { cls: "btn btn--tiny", text: t("windowRemove"), type: "button", onclick: "PPX.windowRemove(" + index + ")" })
    ]));
  });
  if (!mesh.idleWindows.length) { host.appendChild(note(t("windowEmpty"))); }
}
function buildSentinelForm() {
  var slot = el("sentinel");
  clear(slot);
  var sentinel = S.form.sentinel = S.form.sentinel || {};
  var flags = h("div", { cls: "list" });
  flags.appendChild(checkField("clipboard", function () { return sentinel.clipboardClear; }, function (value) { sentinel.clipboardClear = value; }));
  flags.appendChild(checkField("lockScreen", function () { return sentinel.lockScreen; }, function (value) { sentinel.lockScreen = value; }));
  flags.appendChild(checkField("sleepDisplays", function () { return sentinel.sleepDisplays; }, function (value) { sentinel.sleepDisplays = value; }));
  slot.appendChild(flags);
  slot.appendChild(h("hr", { cls: "hair" }));
  slot.appendChild(h("span", { cls: "field__label", text: t("mounts") }));
  slot.appendChild(h("div", { id: "mount-list", cls: "list" }));
  renderMountList();
  slot.appendChild(h("button", { cls: "btn btn--mini", text: t("mountAdd"), type: "button", onclick: "PPX.mountAdd()" }));
  slot.appendChild(note(t("mountHint")));
  slot.appendChild(h("hr", { cls: "hair" }));
  var grid = h("div", { cls: "fields fields--wide" });
  grid.appendChild(urlField("hookUrl", function () { return sentinel.webhookURL; }, function (value) { sentinel.webhookURL = value; }, "http://homeassistant.local:8123/api/webhook/…", "hookUrl"));
  grid.appendChild(secretField("hookSecret", function () { return sentinel.webhookSecret; }, function (value) { sentinel.webhookSecret = value; }));
  slot.appendChild(grid);
  slot.appendChild(textField("phrases", function () { return (sentinel.triggerPhrases || []).join(", "); },
    function (value) {
      sentinel.triggerPhrases = value.split(",").map(function (item) { return item.trim(); }).filter(function (item) { return item.length; });
    }, null, null));
  slot.appendChild(h("div", { id: "sentinel-live", cls: "engine__meta" }));
  slot.appendChild(h("button", { cls: "btn btn--primary", text: t("drill"), type: "button", onclick: "PPX.drill()" }));
}
function renderMountList() {
  var host = el("mount-list");
  if (!host) { return; }
  clear(host);
  var sentinel = S.form.sentinel;
  sentinel.unmountPaths = sentinel.unmountPaths || [];
  sentinel.unmountPaths.forEach(function (item, index) {
    var input = h("input", { type: "text", spellcheck: "false", value: String(item) });
    input.addEventListener("input", function () { sentinel.unmountPaths[index] = input.value; markDirty(); });
    host.appendChild(h("div", { cls: "list__row" }, [
      input,
      h("button", { cls: "btn btn--tiny", text: t("windowRemove"), type: "button", onclick: "PPX.mountRemove(" + index + ")" })
    ]));
  });
  if (!sentinel.unmountPaths.length) { host.appendChild(note(t("mountEmpty"))); }
}
function buildArkForm() {
  var slot = el("ark");
  clear(slot);
  var ark = S.form.ark = S.form.ark || {};
  var grid = h("div", { cls: "fields" });
  grid.appendChild(numField("beat", function () { return ark.heartbeatIntervalHours || 1; }, function (value) { ark.heartbeatIntervalHours = value; }, 1, 8760, null));
  grid.appendChild(numField("missed", function () { return ark.missedHeartbeatsBeforeRelease || 1; }, function (value) { ark.missedHeartbeatsBeforeRelease = value; }, 1, 24, null));
  grid.appendChild(numField("lockDur", function () { return ark.timelockSeconds || 60; }, function (value) { ark.timelockSeconds = value; }, 60, 315360000,
    t("lockDays") + " " + Math.round((Number(ark.timelockSeconds) || 0) / 86400) + " " + t("daysUnit"),
    function (value) { return t("lockDays") + " " + Math.round(value / 86400) + " " + t("daysUnit"); }));
  slot.appendChild(grid);
  var people = h("div", { cls: "fields fields--wide" });
  people.appendChild(textField("beneficiary", function () { return ark.beneficiaryName; }, function (value) { ark.beneficiaryName = value; }, null, null));
  people.appendChild(textField("beneficiaryQueue", function () { return ark.beneficiaryQueue; }, function (value) { ark.beneficiaryQueue = value; }, "smp://…", null));
  slot.appendChild(people);
  slot.appendChild(h("hr", { cls: "hair" }));
  /* The capsule folder is fixed by the node and is not a field of ArkConfig,
     so it is shown read-only: an editable box here would be a control the
     engine never reads back, and a page cannot host NSOpenPanel. */
  slot.appendChild(fieldWrap("directory", h("span", { cls: "mono", text: "vault/sealed/" }), note(t("dirHint"))));
  slot.appendChild(h("div", { cls: "btn-row" }, [
    h("button", { cls: "btn btn--mini", text: t("dirReveal"), type: "button", onclick: "PPX.revealDir()" })
  ]));
  slot.appendChild(note(t("dirUnsupported")));
  slot.appendChild(h("hr", { cls: "hair" }));
  slot.appendChild(h("span", { cls: "field__label", text: t("archives") }));
  slot.appendChild(h("div", { id: "ark-live", cls: "stack" }));
}

function buildSettingsForm() {
  if (!S.form) { return; }
  buildMeshForm();
  buildSentinelForm();
  buildArkForm();
  buildPrivacyForm();
}
function renderSettingsViews() {
  var snap = S.snap;
  var mesh = snap.mesh || {};
  var meshTag = el("mesh-tag");
  meshTag.textContent = mesh.sharingEnabled ? t("meshOn") : t("meshOff");
  meshTag.className = "tag " + (mesh.sharingEnabled ? (mesh.acceptingNow ? "tag--ok" : "tag--accent") : "tag--off");
  var live = el("mesh-live");
  if (live) {
    clear(live);
    live.appendChild(h("div", { cls: "engine__meta" }, [
      h("span", {}, [t(mesh.acceptingNow ? "acceptingNow" : "notAcceptingNow"), h("i", { text: mesh.acceptingNow ? t("yes") : t("no") })]),
      h("span", {}, [t("activeJobs") + " ", h("i", { text: String(mesh.activeJobs || 0) })]),
      h("span", {}, [t("accrued") + " ", h("i", { text: String(mesh.accruedPoints || 0) })]),
      h("span", {}, [t("settled") + " ", h("i", { text: String(mesh.completedJobs || 0) })]),
      h("span", {}, [t("meshSandbox") + " ", h("i", { text: bytes(mesh.sandboxBytesUsed) })]),
      h("span", {}, [t("nextWindow") + " ", h("i", { text: String(mesh.nextWindowLabel || t("never")) })])
    ]));
  }
  var sentinelDocument = snap.settings ? snap.settings.sentinel : null;
  var sentinelTag = el("sentinel-tag");
  var armed = Boolean(sentinelDocument && ((sentinelDocument.unmountPaths || []).length ||
    sentinelDocument.webhookURL || sentinelDocument.clipboardClear || sentinelDocument.lockScreen));
  sentinelTag.textContent = armed ? t("sentinelOn") : t("sentinelOff");
  sentinelTag.className = "tag " + (armed ? "tag--ok" : "tag--off");
  var sentinelLive = el("sentinel-live");
  if (sentinelLive) {
    clear(sentinelLive);
    var last = (snap.lockdowns || [])[0];
    sentinelLive.appendChild(h("span", { cls: "tag", text: t("receiptTrigger") + " " + (last ? String(last.trigger) : t("never")) }));
    sentinelLive.appendChild(h("span", { cls: "tag", text: t("receiptElapsed") + " " + (last ? String(last.elapsedMs) + " ms" : "—") }));
    sentinelLive.appendChild(h("span", { cls: "tag", text: t("modelFree") + " " + (last && last.modelInvolved ? t("no") : t("yes")) }));
  }
  var ark = snap.settings ? snap.settings.ark : null;
  var arkTag = el("ark-tag");
  var deadline = ark && ark.lastHeartbeatAt
    ? new Date(ark.lastHeartbeatAt).getTime() +
      (Number(ark.heartbeatIntervalHours || 72) * Math.max(1, Number(ark.missedHeartbeatsBeforeRelease || 4)) * 3600000)
    : null;
  var overdue = deadline !== null && deadline < nodeNow();
  arkTag.textContent = overdue ? t("arkAlert") : t("arkOk");
  arkTag.className = "tag " + (overdue ? "tag--bad" : "tag--ok");
  var arkLive = el("ark-live");
  if (arkLive) {
    clear(arkLive);
    if (deadline !== null) {
      arkLive.appendChild(h("div", { cls: "engine__meta" }, [
        h("span", {}, [t("graceDue") + " ", h("i", { text: stampOf(new Date(deadline)) + " · " + relTime(new Date(deadline)) })])
      ]));
    }
    var vaults = snap.vaults || [];
    if (!vaults.length) { arkLive.appendChild(emptyState("archivesEmpty")); }
    else {
      var table = h("table", { cls: "table" });
      var head = document.createElement("tr");
      ["archives", "archiveSealedAt", "archiveOpens", "archiveFingerprint", "archiveSealed"].forEach(function (key) {
        head.appendChild(h("th", { text: t(key) }));
      });
      var thead = document.createElement("thead");
      thead.appendChild(head);
      table.appendChild(thead);
      var body = document.createElement("tbody");
      vaults.forEach(function (vault) {
        var openable = new Date(vault.earliestOpenAt).getTime() <= nodeNow();
        var row = document.createElement("tr");
        row.appendChild(h("td", {}, [
          h("div", { cls: "cell-strong", text: String(vault.label || t("unknown")) }),
          h("div", { cls: "mono mute", text: anon(String(vault.path || "")) })
        ]));
        row.appendChild(h("td", { text: stampOf(dateOf(vault.sealedAt)) }));
        row.appendChild(h("td", { text: stampOf(dateOf(vault.earliestOpenAt)) }));
        row.appendChild(h("td", { cls: "mono", text: String(vault.derivedKeyFingerprint || "").slice(0, 12) + " · " + String(vault.rounds || 0) }));
        row.appendChild(h("td", {}, h("span", {
          cls: "tag " + (openable || vault.released ? "tag--ok" : "tag--off"),
          text: vault.released ? t("released") : openable ? t("archiveOpen") : t("archiveSealed")
        })));
        body.appendChild(row);
      });
      table.appendChild(body);
      arkLive.appendChild(table);
    }
  }
  renderLockdowns();
}
var RECEIPT_FIELDS = [
  ["trigger", null], ["clipboardCleared", "receiptClip"], ["screenLocked", "receiptScreen"],
  ["displaysSlept", "sleepDisplays"], ["unmounted", "receiptUnmount"], ["mountFailures", "receiptMountFail"],
  ["webhookStatus", "receiptWebhook"], ["webhookTarget", "receiptWebhook"], ["elapsedMs", "receiptElapsed"],
  ["modelInvolved", "modelUsed"]
];
function receiptValue(value) {
  if (Array.isArray(value)) { return value.map(function (item) { return anon(String(item)); }).join(", ") || "—"; }
  if (value === true) { return t("yes"); }
  if (value === false) { return t("no"); }
  if (value === null || value === undefined) { return "—"; }
  return anon(String(value));
}
function receiptCard(receipt, accent) {
  var card = h("div", { cls: "stat" });
  if (accent) { card.style.setProperty("border-color", "rgba(139,108,255,.5)"); }
  card.appendChild(h("span", {
    cls: "stat__k",
    text: stampOf(dateOf(receipt.triggeredAt)) + " · " + String(receipt.trigger || "")
  }));
  card.appendChild(h("span", {
    cls: "stat__v stat__v--sm mono",
    text: String(receipt.elapsedMs || 0) + " ms · " + (receipt.modelInvolved ? t("modelUsed") : t("modelFree"))
  }));
  var detail = [];
  RECEIPT_FIELDS.forEach(function (pair) {
    if (!pair[1] || receipt[pair[0]] === undefined) { return; }
    detail.push(t(pair[1]) + " " + receiptValue(receipt[pair[0]]));
  });
  card.appendChild(h("span", { cls: "stat__n", text: detail.join("  ·  ") }));
  return card;
}
function renderLockdowns() {
  var slot = el("drill");
  clear(slot);
  if (S.drillResult) { slot.appendChild(drillCard(S.drillResult)); }
  var receipts = (S.snap && S.snap.lockdowns) || [];
  if (!receipts.length && !S.drillResult) { slot.appendChild(emptyState("receiptEmpty")); return; }
  receipts.slice(0, 6).forEach(function (receipt) { slot.appendChild(receiptCard(receipt, false)); });
}
function drillCard(result) {
  var card = h("div", { cls: "stat" });
  card.style.setProperty("border-color", result.ok ? "rgba(63,214,143,.5)" : "rgba(255,107,120,.5)");
  card.appendChild(h("span", { cls: "stat__k", text: (result.ok ? "✓ " : "✕ ") + String(result.headline || t("unknown")) }));
  card.appendChild(h("span", {
    cls: "stat__v stat__v--sm mono",
    text: String(result.durationMs || 0) + " ms · " + (result.deterministic ? t("modelFree") : t("modelUsed"))
  }));
  if (result.body) { card.appendChild(h("span", { cls: "stat__n", text: String(result.body) })); }
  var metrics = result.metrics || {};
  var receipt = metrics.receipt || metrics.lockdown || metrics.LockdownReceipt || null;
  if (receipt && typeof receipt === "object") {
    Object.keys(receipt).sort().forEach(function (key) {
      card.appendChild(h("div", { cls: "engine__meta" }, [
        h("span", { text: key }), h("i", { text: receiptValue(receipt[key]) })
      ]));
    });
  }
  (result.artifacts || []).forEach(function (path) {
    card.appendChild(h("span", { cls: "mono mute", text: anon(String(path)) }));
  });
  return card;
}
var SAVE_BARS = [
  ["save-text", "save-rev", "btn-save"],
  ["pv-save-text", "pv-save-rev", "pv-save"],
  ["hv-save-text", "hv-save-rev", "hv-save"]
];
/* Three steps post the same settings document, so every bar must tell the truth about it:
   leaving one static would let a panel claim 「已保存」 while another was still dirty. */
function renderSaveBar() {
  var label = S.saving ? t("saving") : (S.dirty ? t("dirty") : t("saved"));
  var kind = S.saving || S.dirty ? "savebar__text is-dirty" : "savebar__text";
  SAVE_BARS.forEach(function (bar) {
    var text = el(bar[0]);
    if (!text) { return; }
    text.textContent = label;
    text.className = kind;
    setText(bar[1], t("revision") + " " + String(S.formBase) + " · " + t("now") + " " + String(nodeRevision()));
    var button = el(bar[2]);
    if (!button) { return; }
    button.textContent = S.saving ? t("saving") : t("save");
    button.classList.toggle("is-disabled", S.saving || !S.dirty);
  });
}

/* -------------------------------------------------------------- step four */
/* The privacy panel renders the snapshot's own cards. The node discards event titles,
   locations and attendees before it encodes them, so this page has no raw calendar text
   to leak even if a caller injected one: every string below is a bucket count, a stamp,
   or a ref the node minted. */
function pvSnap() { return (S.snap && S.snap.privacy) || {}; }
/* Called only from renderers and from `buildSettingsForm`, never the other way round:
   `ensureForm` is what invokes the builders, so a builder that asked for the form again
   would recurse. */
function pvConfig() {
  if (!S.form) { return null; }
  // Seeded from the config the engine is actually running, never from a copy of Swift's
  // defaults written down here.
  if (!S.form.privacyBridges) { S.form.privacyBridges = clone(pvSnap().bridges || {}); }
  return S.form.privacyBridges;
}
function pvWhen(iso) {
  var date = dateOf(iso);
  if (!date) { return t("never"); }
  function pad(x) { return x < 10 ? "0" + x : String(x); }
  return pad(date.getMonth() + 1) + "-" + pad(date.getDate()) + " " + pad(date.getHours()) + ":" + pad(date.getMinutes());
}
/* Spelled out one `t()` call per value so the catalog gate in the contract test can see
   every key: a lookup table would hide a missing string behind a silent empty label. */
function pvActionLabel(action) {
  if (action === "create") { return t("pvActCreate"); }
  if (action === "reschedule") { return t("pvActReschedule"); }
  if (action === "cancel") { return t("pvActCancel"); }
  if (action === "write") { return t("pvActWrite"); }
  if (action === "organize") { return t("pvActOrganize"); }
  if (action === "invoke") { return t("pvActInvoke"); }
  return String(action || "—");
}
function pvStateLabel(state) {
  if (state === "pending_user_approval") { return t("pvStatePending"); }
  if (state === "approved") { return t("pvStateApproved"); }
  if (state === "executed") { return t("pvStateExecuted"); }
  if (state === "rejected") { return t("pvStateRejected"); }
  if (state === "expired") { return t("pvStateExpired"); }
  if (state === "failed") { return t("pvStateFailed"); }
  if (state === "cancelled") { return t("pvStateCancelled"); }
  return String(state || "—");
}
function pvDomainLabel(domain) {
  if (domain === "calendar") { return t("pvDomainCal"); }
  if (domain === "workspace") { return t("pvDomainWs"); }
  // The ledger stores the audit domain, so a hub card says `smartHome` where the owner
  // typed `home`. Listing both here is what keeps a device proposal from being filed
  // under "workspace" on the page the owner uses to approve it.
  if (domain === "mcp") { return t("pvDomainMCP"); }
  if (domain === "smartHome" || domain === "home") { return t("pvDomainHome"); }
  return String(domain || "—");
}
function pvTag(text, kind) { return h("span", { cls: "tag" + (kind ? " tag--" + kind : ""), text: text }); }
function pvPendingCards() {
  return (pvSnap().pendingProposals || []).filter(function (card) { return card.state === "pending_user_approval"; });
}

/* ---------------------------------------------------------------- the form */
function buildPrivacyForm() {
  var access = el("pv-access"), rules = el("pv-rules");
  var cfg = pvConfig();
  if (cfg) {
    if (access) {
      clear(access);
      var box = h("div", { cls: "list" });
      box.appendChild(checkField("pvCalSwitch", function () { return cfg.allowCalendarAccess; },
        function (value) { cfg.allowCalendarAccess = value; }));
      box.appendChild(checkField("pvReadSwitch", function () { return cfg.allowWorkspaceRead; },
        function (value) { cfg.allowWorkspaceRead = value; }));
      box.appendChild(checkField("pvWriteSwitch", function () { return cfg.allowWorkspaceWrite; },
        function (value) { cfg.allowWorkspaceWrite = value; }));
      box.appendChild(checkField("pvNotifySwitch", function () { return cfg.notifyOnProposal; },
        function (value) { cfg.notifyOnProposal = value; }));
      access.appendChild(box);
    }
    if (rules) { buildPrivacyRules(rules, cfg); }
  }
  renderPvDirRows();
}
function buildPrivacyRules(slot, cfg) {
  clear(slot);
  var grid = h("div", { cls: "fields" });
  grid.appendChild(numField("pvWorkStart", function () { return Number(cfg.workingStartHour) || 9; },
    function (value) { cfg.workingStartHour = value; }, 0, 23, null));
  grid.appendChild(numField("pvWorkEnd", function () { return Number(cfg.workingEndHour) || 18; },
    function (value) { cfg.workingEndHour = value; }, 1, 24, null));
  grid.appendChild(numField("pvDuration", function () { return Number(cfg.defaultDurationMinutes) || 30; },
    function (value) { cfg.defaultDurationMinutes = value; }, 5, 720, null));
  grid.appendChild(numField("pvBuffer", function () { return Number(cfg.bufferMinutes) || 0; },
    function (value) { cfg.bufferMinutes = value; }, 0, 240, null));
  slot.appendChild(grid);
  var lunch = h("div", { cls: "fields" });
  lunch.appendChild(numField("pvLunchStart", function () { return Number(cfg.lunchStartHour) || 12; },
    function (value) { cfg.lunchStartHour = value; }, 0, 23, null));
  lunch.appendChild(numField("pvLunchEnd", function () { return Number(cfg.lunchEndHour) || 13; },
    function (value) { cfg.lunchEndHour = value; }, 1, 24, null));
  slot.appendChild(lunch);
  slot.appendChild(checkField("pvBlockLunch", function () { return cfg.blockLunch; },
    function (value) { cfg.blockLunch = value; }));
  slot.appendChild(h("span", { cls: "field__label", text: t("pvWorkdays") }));
  slot.appendChild(pvWorkdayPicker(cfg));
  slot.appendChild(h("hr", { cls: "hair" }));
  slot.appendChild(textField("pvZone", function () { return cfg.timezoneIdentifier; },
    function (value) { cfg.timezoneIdentifier = value; }, null, "pvZoneNote"));
  slot.appendChild(textField("pvCallTemplate", function () { return cfg.callLinkTemplate; },
    function (value) { cfg.callLinkTemplate = value; }, null, "pvCallNote"));
}
/* The node stores ISO weekdays (1 = Monday … 7 = Sunday) while the shared weekday strip
   is Apple's 0-based, Sunday-first order, so the two are converted at this edge only. */
function pvWorkdayPicker(cfg) {
  var host = h("div", { cls: "weekdays" });
  var labels = WEEKDAYS[catalogFor(S.lang)] || WEEKDAYS.en;
  function local(days) { return (days || []).map(function (day) { return day % 7; }); }
  [1, 2, 3, 4, 5, 6, 0].forEach(function (day) {
    var button = h("button", { type: "button", text: labels[day], title: labels[day] });
    button.classList.toggle("is-on", local(cfg.workdays).indexOf(day) >= 0);
    button.addEventListener("click", function () {
      var list = local(cfg.workdays);
      var position = list.indexOf(day);
      if (position >= 0) { list.splice(position, 1); } else { list.push(day); }
      cfg.workdays = list.map(function (value) { return value === 0 ? 7 : value; }).sort(function (a, b) { return a - b; });
      button.classList.toggle("is-on", list.indexOf(day) >= 0);
      markDirty();
    });
    host.appendChild(button);
  });
  return host;
}
function renderPvDirRows() {
  var host = el("pv-dirs"), cfg = pvConfig();
  if (!host || !cfg) { return; }
  clear(host);
  cfg.workspaceDirectories = cfg.workspaceDirectories || [];
  cfg.workspaceDirectories.forEach(function (item, index) {
    var input = h("input", { type: "text", spellcheck: "false", value: String(item), placeholder: "~/Documents/…" });
    input.addEventListener("input", function () { cfg.workspaceDirectories[index] = input.value; markDirty(); });
    host.appendChild(h("div", { cls: "list__row" }, [
      input,
      h("button", { cls: "btn btn--tiny", text: t("pvDirRemove"), type: "button", onclick: "PPX.pvRemoveDir(" + index + ")" })
    ]));
  });
  if (!cfg.workspaceDirectories.length) { host.appendChild(note(t("pvDirEmpty"))); }
}

/* ------------------------------------------------------------- the readouts */
function renderPrivacyStats() {
  var privacy = pvSnap(), slot = el("pv-stats");
  if (!slot) { return; }
  clear(slot);
  slot.appendChild(h("div", { cls: "stat" }, [
    h("span", { cls: "stat__k", text: t("pvStatPending") }),
    h("span", { cls: "stat__v", text: String(pvPendingCards().length) })
  ]));
  slot.appendChild(h("div", { cls: "stat" }, [
    h("span", { cls: "stat__k", text: t("pvStatBookings") }),
    h("span", { cls: "stat__v", text: String((privacy.bookings || []).length) })
  ]));
  slot.appendChild(h("div", { cls: "stat" }, [
    h("span", { cls: "stat__k", text: t("pvStatDirs") }),
    h("span", { cls: "stat__v stat__v--sm", text: String((privacy.reachableDirectories || []).length) + " / " + String(privacy.directoryCeiling || 0) }),
    h("span", { cls: "stat__n", text: t("pvStatDirsNote") })
  ]));
  var badge = el("pv-badge");
  if (badge) {
    var pending = pvPendingCards().length;
    badge.textContent = pending ? t("pvBadgePending") + " " + String(pending) : t("pvBadgeQuiet");
    badge.className = "tag" + (pending ? " tag--warn" : " tag--off");
  }
  var tag = el("pv-prop-tag");
  if (tag) {
    var count = pvPendingCards().length;
    tag.textContent = String(count);
    tag.className = "tag" + (count ? " tag--warn" : "");
  }
}
function renderPrivacyControls() {
  var privacy = pvSnap(), cfg = pvConfig();
  var state = String(privacy.eventAuthorization || "notDetermined");
  var granted = state === "authorized" || state === "fullAccess";
  var tag = el("pv-auth-tag");
  if (tag) {
    tag.textContent = state;
    tag.className = "tag " + (granted ? "tag--ok" : state === "notDetermined" ? "tag--off" : "tag--bad");
  }
  var checkOut = el("pv-check-out");
  if (checkOut) { checkOut.textContent = pvCheckText(); }
  var ask = el("pv-ask");
  if (ask) {
    ask.classList.toggle("is-disabled", !(cfg && cfg.allowCalendarAccess));
    ask.textContent = granted ? t("pvAuthAgain") : t("pvAskAccess");
  }
  var add = el("pv-adddir");
  if (add) {
    var dirs = (cfg && cfg.workspaceDirectories) || [];
    add.classList.toggle("is-disabled", dirs.length >= Number(privacy.directoryCeiling || 0));
  }
  var known = el("pv-dirs-known");
  if (known) {
    clear(known);
    var reachable = privacy.reachableDirectories || [];
    (privacy.directories || []).forEach(function (path) {
      var open = reachable.indexOf(path) >= 0;
      known.appendChild(h("div", { cls: "list__row" }, [
        h("span", { cls: "dot" + (open ? " dot--ok" : " dot--bad"), title: open ? t("pvDirOpen") : t("pvDirClosed") }),
        h("span", { cls: "pv-line mono", text: path })
      ]));
    });
    if (!(privacy.directories || []).length) { known.appendChild(h("div", { cls: "pv-line", text: t("pvDirNoneSaved") })); }
  }
}
function renderPrivacyProposals() {
  var host = el("pv-proposals");
  if (!host) { return; }
  clear(host);
  var cards = pvSnap().pendingProposals || [];
  if (!cards.length) { host.appendChild(h("div", { cls: "empty", text: t("pvNone") })); return; }
  cards.forEach(function (card) { host.appendChild(pvProposalCard(card)); });
}
/* One card, built by both panels. The hub panel filters the same ledger list down to its
   two domains, and a second copy of this markup is how the two would drift into two
   different answers about whether a proposal was clickable. */
function pvProposalCard(card) {
    var pending = card.state === "pending_user_approval";
    var box = h("div", { cls: "pv-card" + (pending ? "" : " is-spent") });
    box.appendChild(h("div", { cls: "pv-top" }, [
      h("span", { cls: "pv-title", text: pvActionLabel(card.action) }),
      pvTag(pvDomainLabel(card.domain)),
      pvTag(pvStateLabel(card.state), pending ? "warn" : card.state === "executed" ? "ok" : "off"),
      h("span", {
        cls: "pv-ttl" + (pending && Number(card.secondsLeft) > 0 && Number(card.secondsLeft) < 60 ? " is-soon" : ""),
        text: pending ? dur(card.secondsLeft) : ""
      })
    ]));
    if (card.title) { box.appendChild(h("div", { cls: "pv-line", text: String(card.title) })); }
    if (card.startISO) {
      box.appendChild(h("div", { cls: "pv-meta", text: pvWhen(card.startISO) + (card.endISO ? " → " + pvWhen(card.endISO) : "") }));
    }
    if (card.path) { box.appendChild(h("div", { cls: "pv-meta", text: anon(card.path) })); }
    if (card.detail) { box.appendChild(h("div", { cls: "pv-line", text: String(card.detail).slice(0, 300) })); }
    if (card.bookingRef) { box.appendChild(h("div", { cls: "pv-meta", text: String(card.bookingRef) })); }
    var acts = h("div", { cls: "pv-acts" });
    if (pending) {
      ["approve", "reject"].forEach(function (verb) {
        acts.appendChild(h("button", {
          cls: "btn btn--mini " + (verb === "approve" ? "btn--ok" : "btn--bad"),
          text: verb === "approve" ? t("pvApprove") : t("pvReject"),
          type: "button",
          "data-id": String(card.id || ""), "data-domain": String(card.domain || ""), "data-verb": verb,
          "data-label": verb === "approve" ? t("pvApprove") : t("pvReject"),
          onclick: "PPX.pvDecide(this)"
        }));
      });
      if (!card.canApprove) { acts.appendChild(note(t("pvCannotApprove"))); }
    }
    box.appendChild(acts);
    return box;
}
function renderPrivacyBookings() {
  var host = el("pv-bookings");
  if (!host) { return; }
  clear(host);
  var rows = pvSnap().bookings || [];
  var tag = el("pv-book-tag");
  if (tag) { tag.textContent = String(rows.length); }
  if (!rows.length) { host.appendChild(h("div", { cls: "empty", text: t("pvNoBookings") })); return; }
  rows.forEach(function (row) {
    host.appendChild(h("div", { cls: "pv-card is-live" }, [
      h("div", { cls: "pv-top" }, [
        h("span", { cls: "pv-title", text: pvActionLabel(row.action) }),
        pvTag("#" + String(row.sequence || 1), "accent"),
        h("span", { cls: "pv-ttl mono", text: String(row.ref || "") })
      ]),
      row.title ? h("div", { cls: "pv-line", text: String(row.title) }) : null,
      h("div", { cls: "pv-meta", text: pvWhen(row.startISO) + (row.endISO ? " → " + pvWhen(row.endISO) : "") })
    ]));
  });
}
function renderPrivacyAudit() {
  var host = el("pv-audit");
  if (!host) { return; }
  clear(host);
  var rows = pvSnap().auditLog || [];
  if (!rows.length) { host.appendChild(h("div", { cls: "empty", text: t("pvNoAudit") })); return; }
  rows.forEach(function (row) {
    host.appendChild(h("div", { cls: "pv-log__row" }, [
      h("span", { cls: "pv-log__at", text: pvWhen(row.at) }),
      h("span", { cls: "pv-log__tx", text: [pvDomainLabel(row.domain), pvActionLabel(row.action), row.outcome, row.detail]
        .filter(function (piece) { return piece !== null && piece !== undefined && String(piece).length; })
        .join(" · ") })
    ]));
  });
}
function renderStep4() {
  ensureForm(S.snap);
  renderPrivacyStats();
  renderPrivacyControls();
  renderPrivacyProposals();
  renderPrivacyBookings();
  renderPrivacyAudit();
  renderSaveBar();
}
/* A second label, ticked down here rather than re-fetched: the poll carries the whole
   card list, and rebuilding it every second would drop an armed confirmation button. */
function updatePvCountdown() {
  if (S.step !== 4) { return; }
  var cards = pvSnap().pendingProposals || [];
  var index = 0;
  Array.prototype.forEach.call(document.querySelectorAll("#pv-proposals .pv-ttl"), function (node) {
    var card = cards[index]; index += 1;
    if (!card || card.state !== "pending_user_approval" || !card.expiresISO) { return; }
    var left = Math.round((new Date(card.expiresISO).getTime() - nodeNow()) / 1000);
    if (isNaN(left)) { return; }
    node.textContent = left > 0 ? dur(left) : t("pvTtlOver");
    node.classList.toggle("is-soon", left > 0 && left < 60);
  });
}

/* ---------------------------------------------------------------- step five */
/* The two hub cards. Everything here is read from the node: the switches come from the saved
   settings document, the capability rows from the discovery actor, the bridge lines from the
   same `/v1/tools/…/status` routes a paired phone calls. The page holds no endpoint it did not
   get from the node, and no secret it ever shows back. */
function hvSaved() { return (S.snap && S.snap.settings && S.snap.settings.hubBridges) || {}; }
function hvConfig() {
  if (!S.form) { return null; }
  if (!S.form.hubBridges) { S.form.hubBridges = clone(hvSaved()); }
  var cfg = S.form.hubBridges;
  cfg.discovery = cfg.discovery || clone(hvSaved().discovery || {});
  cfg.smartHome = cfg.smartHome || clone(hvSaved().smartHome || {});
  cfg.calDav = cfg.calDav || clone(hvSaved().calDav || {});
  cfg.smartHome.exposedEntities = cfg.smartHome.exposedEntities || [];
  cfg.discovery.lanTargets = cfg.discovery.lanTargets || [];
  return cfg;
}
function hvAnyOn() {
  var cfg = (S.form && S.form.hubBridges) || hvSaved();
  return Boolean(cfg.allowMcpBridge || cfg.allowSmartHomeBridge || cfg.allowCalDavBridge);
}
function hvPendingCards() {
  return ((pvSnap().pendingProposals) || []).filter(function (card) {
    return card.domain === "mcp" || card.domain === "smartHome" || card.domain === "home";
  });
}
function hvKindLabel(kind) {
  if (kind === "ollama") { return t("hvKindEngine"); }
  if (kind === "model") { return t("hvKindModel"); }
  if (kind === "workspace") { return t("hvKindWorkspace"); }
  if (kind === "calendar") { return t("hvKindCalendar"); }
  if (kind === "lanService") { return t("hvKindLan"); }
  if (kind === "refusal") { return t("hvKindRefused"); }
  return String(kind || "—");
}
/* Written out one `t()` per value, for the same reason `pvStateLabel` is: a lookup table
   hides a missing string behind an empty cell, and the catalog gate cannot see it. */
function hvStateLabel(state) {
  if (state === "present") { return t("hvStatePresent"); }
  if (state === "absent") { return t("hvStateAbsent"); }
  if (state === "installed") { return t("hvStateInstalled"); }
  if (state === "authorized") { return t("hvStateAuthorized"); }
  if (state === "denied") { return t("hvStateDenied"); }
  if (state === "off") { return t("hvStateOff"); }
  if (state === "reachable") { return t("hvStateReachable"); }
  if (state === "silent") { return t("hvStateSilent"); }
  if (state === "refused") { return t("hvStateRefused"); }
  if (state === "fullAccess") { return t("hvStateFull"); }
  if (state === "writeAccess") { return t("hvStateWrite"); }
  if (state === "restricted") { return t("hvStateRestricted"); }
  if (state === "notDetermined") { return t("hvStateNotAsked"); }
  if (state === "noGateway") { return t("hvStateNoBridge"); }
  return String(state || "—");
}
function hvStateKind(state) {
  if (state === "present" || state === "installed" || state === "authorized"
    || state === "reachable" || state === "fullAccess" || state === "writeAccess") { return "ok"; }
  if (state === "denied" || state === "refused" || state === "restricted") { return "bad"; }
  return "off";
}
function hvPoll() {
  api(ROUTE.discoveryCapabilities).then(function (reply) {
    S.discovery = reply || {};
    renderDiscovery();
  }).catch(function () { /* the card keeps its last answer; a failed poll is not a finding */ });
  hvStatus();
}
function hvScan() {
  var button = el("hv-scan");
  if (button) { button.classList.add("is-disabled"); button.textContent = t("hvScanning"); }
  function done() {
    if (button) {
      button.classList.remove("is-disabled");
      button.textContent = t("hvScan");
    }
  }
  api(ROUTE.discoveryScan, { method: "POST", json: {} }).then(function (reply) {
    S.discovery = reply || {};
    renderDiscovery();
    done();
  }).catch(function (error) {
    done();
    fail("hvScanFailed", error);
  });
}
function hvStatus() {
  S.hubPending = true;
  renderHubStatus();
  var jobs = [
    ["mcp", ROUTE.toolMCPStatus],
    ["home", ROUTE.toolHomeStatus],
    ["calDav", ROUTE.toolCalDavStatus]
  ];
  var settled = 0;
  function settle() {
    settled += 1;
    if (settled >= jobs.length) { S.hubPending = false; }
    renderHubStatus();
  }
  jobs.forEach(function (job) {
    api(job[1], { method: "POST", json: {} }).then(function (reply) {
      S.hub = S.hub || {};
      S.hub[job[0]] = { ok: true, data: reply || {} };
      settle();
    }).catch(function (error) {
      S.hub = S.hub || {};
      S.hub[job[0]] = {
        ok: false,
        // A refused bridge answers 403 with `refusal`, and that sentence names the missing
        // switch. Swallowing it into "403" would leave the owner guessing which of the three.
        message: String((error && error.message) || job[0])
      };
      settle();
    });
  });
}
/* The credential path is console-only and one-way: the value goes out in a POST body, the
   reply carries only the Keychain reference, and nothing is written into `S.form`, so the
   settings document the save bar posts can never carry a token. Implemented as `hvStore`,
   next to the draft holder it reads. */
/* --------------------------------------------------- global intelligence map */
/* One card, two sources of truth: the saved document says what the owner asked for,
   the snapshot says what the node measured. Every button posts one verb; the bridge
   re-checks each precondition, so a stale page cannot start a program that was just
   switched off. Credentials follow the hub card's one-way path: the value leaves in a
   POST body and only a Keychain reference comes back. */
var GE_BUSY = false;
var GE_SOURCES = [
  { id: "aisstream", env: "AISSTREAM_API_KEY" },
  { id: "opensky-client-id", env: "OPENSKY_CLIENT_ID" },
  { id: "opensky-client-secret", env: "OPENSKY_CLIENT_SECRET" }
];
function geSaved() { return (S.snap && S.snap.settings && S.snap.settings.godsEye) || {}; }
function geSnap() { return (S.snap && S.snap.godsEye) || {}; }
function geConfig() {
  if (!S.form) { return null; }
  if (!S.form.godsEye) { S.form.godsEye = clone(geSaved()); }
  var cfg = S.form.godsEye;
  if (cfg.mode !== "pinnedSource") { cfg.mode = "existing"; }
  if (!cfg.pinnedVersion) { cfg.pinnedVersion = "1.0.0"; }
  if (!cfg.port) { cfg.port = 18931; }
  cfg.credentials = cfg.credentials || {};
  return cfg;
}
function geCredSlot(id) {
  var cfg = geConfig();
  if (!cfg) { return { enabled: false, reference: "" }; }
  if (!cfg.credentials[id]) { cfg.credentials[id] = { enabled: false, reference: "" }; }
  return cfg.credentials[id];
}
function geModeLabel(mode) { return mode === "pinnedSource" ? t("geModePinned") : t("geModeExisting"); }
function geToolLabel(safety) { return safety === "readOnly" ? t("geToolRead") : t("geToolWrite"); }
function geRow(label, value, mono) {
  return h("div", { cls: "list__row" }, [
    h("span", { cls: "pv-line", text: label }),
    h("span", { cls: "pv-meta" + (mono ? " mono" : ""), text: String(value === undefined || value === null || value === "" ? "—" : value) })
  ]);
}
function renderGodsEye() {
  var snap = geSnap();
  var badge = el("ge-badge");
  if (badge) {
    badge.textContent = snap.enabled ? (snap.running ? t("geBadgeRunning") : t("geBadgeOn")) : t("geBadgeOff");
    badge.className = "tag" + (snap.enabled && (snap.running || snap.installVerified) ? " tag--ok" : " tag--off");
  }
  var stats = el("ge-stats");
  if (stats) {
    clear(stats);
    stats.appendChild(statCard("geStatNode", snap.nodeOK ? "v" + String(snap.nodeMajor || "") : t("geAbsent"),
      String(snap.nodeVersion || snap.nodeDetail || ""), true));
    stats.appendChild(statCard("geStatInstall",
      snap.installVerified ? String(snap.installedVersion || snap.pinnedVersion || "") : t("geUnverified"),
      snap.installVerified ? "" : String(snap.installDetail || ""), true));
    stats.appendChild(statCard("geStatPort", String(snap.bindHost || "127.0.0.1") + ":" + String(snap.port || 0),
      snap.running ? t("geRunning") : t("geStopped"), true));
    stats.appendChild(statCard("geStatHealth",
      snap.healthStatus === null || snap.healthStatus === undefined ? "—" : String(snap.healthStatus),
      snap.lastHealthAt ? pvWhen(snap.lastHealthAt) : "", true));
  }
  var state = el("ge-state");
  if (state) {
    clear(state);
    state.appendChild(geRow(t("geStatePath"), snap.installPath || t("geNoPath"), true));
    state.appendChild(geRow(t("geStateMode"), geModeLabel(snap.mode) + " · " + String(snap.pinnedVersion || ""), false));
    state.appendChild(geRow(t("geStateProcess"),
      snap.running ? "pid " + String(snap.pid || "") + (snap.startedAt ? " · " + pvWhen(snap.startedAt) : "") : t("geStopped"), false));
    state.appendChild(geRow(t("geStateVerified"),
      snap.installVerified
        ? String(snap.installDetail || "") + (snap.verifiedAt ? " · " + pvWhen(snap.verifiedAt) : "")
        : t("geUnverified"), false));
    if (snap.lastError) { state.appendChild(geRow(t("geStateError"), String(snap.lastError).slice(0, 240), false)); }
  }
  setText("ge-bound", String(snap.boundary || ""));
  setText("ge-policy", String(snap.dataPolicy || ""));
  setText("ge-licence", String(snap.licence || ""));
  var mcpTag = el("ge-mcp-tag");
  if (mcpTag) {
    mcpTag.textContent = snap.mcpRegistered ? t("geMcpRegistered") : t("geMcpOff");
    mcpTag.className = "tag" + (snap.mcpRegistered ? " tag--ok" : " tag--off");
  }
  var tools = el("ge-tools");
  if (tools) {
    clear(tools);
    var rows = snap.mcpTools || [];
    if (!rows.length) { tools.appendChild(h("div", { cls: "empty", text: t("geToolsIdle") })); }
    rows.forEach(function (row) {
      var readOnly = row.safety === "readOnly";
      tools.appendChild(h("div", { cls: "list__row" }, [
        h("span", { cls: "dot dot--" + (readOnly ? "ok" : "bad") }),
        h("span", { cls: "pv-line mono", text: String(row.name || "") }),
        pvTag(geToolLabel(row.safety), readOnly ? "ok" : "warn")
      ]));
    });
  }
  var mcpNote = el("ge-mcp-note");
  if (mcpNote) { mcpNote.textContent = String(snap.mcpDetail || ""); }
}
function geModeSelect(cfg) {
  var select = h("select");
  [["existing", t("geModeExisting")], ["pinnedSource", t("geModePinned")]].forEach(function (pair) {
    select.appendChild(h("option", { value: pair[0], text: pair[1] }));
  });
  select.value = cfg.mode === "pinnedSource" ? "pinnedSource" : "existing";
  select.addEventListener("change", function () { cfg.mode = select.value; markDirty(); });
  return select;
}
function buildGodsEyeControls() {
  var host = el("ge-switch"), fields = el("ge-fields"), cfg = geConfig();
  if (!cfg) { return; }
  if (host) {
    clear(host);
    host.appendChild(checkField("geSwitch", function () { return cfg.enabled; },
      function (value) { cfg.enabled = value; }));
  }
  if (!fields) { return; }
  clear(fields);
  fields.appendChild(fieldWrap("geMode", geModeSelect(cfg), note(t("geModeNote"))));
  fields.appendChild(textField("gePath", function () { return cfg.installPath; },
    function (value) { cfg.installPath = value; }, "gePathPlaceholder", "gePathNote"));
  fields.appendChild(textField("geVersion", function () { return cfg.pinnedVersion; },
    function (value) { cfg.pinnedVersion = value; }, null, "geVersionNote"));
  fields.appendChild(numField("gePort", function () { return cfg.port || 18931; },
    function (value) { cfg.port = value; }, 1024, 65535, t("gePortNote")));
  fields.appendChild(textField("geNodePath", function () { return cfg.nodePath; },
    function (value) { cfg.nodePath = value; }, "geNodePlaceholder", "geNodeNote"));
  fields.appendChild(urlField("geRepo", function () { return cfg.repositoryURL; },
    function (value) { cfg.repositoryURL = value; }, "https://github.com/", "geRepoNote"));
  fields.appendChild(textField("geRef", function () { return cfg.pinnedRef; },
    function (value) { cfg.pinnedRef = value; }, null, "geRefNote"));
  fields.appendChild(textField("geCommit", function () { return cfg.pinnedCommit; },
    function (value) { cfg.pinnedCommit = value; }, null, "geCommitNote"));
  fields.appendChild(checkField("gePull", function () { return cfg.allowSourcePull; },
    function (value) { cfg.allowSourcePull = value; }));
}
function renderGodsEyeCredentials() {
  var host = el("ge-creds"), cfg = geConfig(), snap = geSnap();
  if (!host || !cfg) { return; }
  clear(host);
  var byID = {};
  (snap.credentials || []).forEach(function (row) { byID[String(row.id || "")] = row; });
  GE_SOURCES.forEach(function (source) {
    var row = byID[source.id] || {};
    var slot = geCredSlot(source.id);
    var input = h("input", { type: "password", spellcheck: "false", autocomplete: "off", placeholder: source.env });
    var store = h("button", { cls: "btn btn--tiny", text: t("geCredStore"), type: "button" });
    store.addEventListener("click", function () { geStoreCredential(source.id, input, store); });
    var on = h("input", { type: "checkbox" });
    on.checked = Boolean(slot.enabled || row.enabled);
    on.addEventListener("change", function () {
      geCredSlot(source.id).enabled = on.checked;
      markDirty();
    });
    host.appendChild(h("div", { cls: "list__row" }, [
      h("span", { cls: "pv-line mono", text: source.env }),
      pvTag(row.stored ? t("geCredStored") : t("geCredMissing"), row.stored ? "ok" : "off"),
      h("label", { cls: "check" }, [on, h("span", { text: t("geSourceOn") })]),
      input,
      store
    ]));
  });
}
function geStoreCredential(sourceId, input, button) {
  var secret = String(input.value || "");
  if (!secret) { toast("warn", t("geCredEmpty")); return; }
  if (button) { button.classList.add("is-disabled"); }
  api(ROUTE.godsEyeCredential, { method: "POST", json: { source: sourceId, secret: secret } })
    .then(function (reply) {
      input.value = "";
      if (button) { button.classList.remove("is-disabled"); }
      var ok = Boolean(reply && reply.ok);
      toast(ok ? "ok" : "err",
        String((reply && reply.detail) || t(ok ? "geCredStored" : "geCredFailed")) + " · " + String((reply && reply.reference) || ""));
      return refreshSnapshot(true);
    })
    .catch(function (error) {
      input.value = "";
      if (button) { button.classList.remove("is-disabled"); }
      fail("geCredFailed", error);
    });
}
function geInvoke(verb) {
  if (GE_BUSY) { return; }
  if (S.dirty) { toast("warn", t("geSaveFirst")); return; }
  var button = el(verb === "start" ? "ge-start" : verb === "stop" ? "ge-stop" : verb === "health" ? "ge-health" : null);
  GE_BUSY = true;
  if (button) { button.classList.add("is-disabled"); }
  function done() {
    GE_BUSY = false;
    if (button) { button.classList.remove("is-disabled"); }
  }
  api(ROUTE.godsEyeControl, { method: "POST", json: { verb: verb } }).then(function (report) {
    done();
    if (report && report.godsEye) { S.snap.godsEye = report.godsEye; }
    renderGodsEye();
    var ok = Boolean(report && report.ok);
    var outcome = String((report && report.outcome) || "");
    toast(ok ? "ok" : outcome === "disabled" ? "warn" : "err",
      String((report && report.detail) || t(ok ? "geActionDone" : "geActionFailed")));
    return refreshSnapshot(true);
  }).catch(function (error) { done(); fail("geActionFailed", error); });
}
function geStart() { geInvoke("start"); }
function geStop() { geInvoke("stop"); }
function geHealth() { geInvoke("health"); }
/* ------------------------------------------ private assistant (personal) */
var AS_REPAIR_LIMIT = 32;
function asSnap() { return (S.snap && S.snap.assistant) || {}; }
function asSaved() { return (S.snap && S.snap.settings && S.snap.settings.assistant) || {}; }
function asConfig() {
  if (!S.form) { return null; }
  if (!S.form.assistant) {
    var saved = asSaved();
    S.form.assistant = {
      enabled: Boolean(saved.enabled),
      briefing: clone(saved.briefing || { enabled: false, hour: 8, minute: 0 }),
      patrol: clone(saved.patrol || { enabled: false, intervalMinutes: 30, offlineMinutes: 15 }),
      mail: clone(saved.mail || {}),
      repairs: clone(saved.repairs || [])
    };
  }
  var cfg = S.form.assistant;
  cfg.briefing = cfg.briefing || { enabled: false, hour: 8, minute: 0 };
  cfg.patrol = cfg.patrol || { enabled: false, intervalMinutes: 30, offlineMinutes: 15 };
  cfg.mail = cfg.mail || {};
  if (!cfg.mail.imapPort) { cfg.mail.imapPort = 993; }
  if (!cfg.mail.smtpPort) { cfg.mail.smtpPort = 465; }
  if (!cfg.mail.imapPasswordRef) { cfg.mail.imapPasswordRef = "assistant/mail/imap-password"; }
  if (!cfg.mail.smtpPasswordRef) { cfg.mail.smtpPasswordRef = "assistant/mail/smtp-password"; }
  if (!cfg.mail.lookbackDays) { cfg.mail.lookbackDays = 3; }
  if (!cfg.mail.maxMessages) { cfg.mail.maxMessages = 12; }
  cfg.repairs = cfg.repairs || [];
  return cfg;
}
/* One `t()` per fixed value: a lookup table would hide a missing label behind an
   empty string the catalog gate cannot see. */
function asConnectorLabel(kind) {
  if (kind === "calendar") { return t("asKindCalendar"); }
  if (kind === "calDav") { return t("asKindCalDav"); }
  if (kind === "smartHome") { return t("asKindSmartHome"); }
  if (kind === "mcp") { return t("asKindMcp"); }
  if (kind === "godsEye") { return t("asKindGodsEye"); }
  if (kind === "mail") { return t("asKindMail"); }
  return t("asKindOther");
}
function asPermLabel(permission) {
  if (permission === "write") { return t("asPermWrite"); }
  if (permission === "admin") { return t("asPermAdmin"); }
  if (permission === "propose") { return t("asPermPropose"); }
  return t("asPermRead");
}
function asPermKind(permission) {
  return permission === "write" || permission === "admin" ? "warn"
    : permission === "propose" ? "accent" : "ok";
}
function renderAssistant() {
  var snap = asSnap(), badge = el("as-badge");
  var pending = snap.pending || [];
  if (badge) {
    badge.textContent = snap.enabled
      ? (pending.length ? t("asBadgePending") + " " + String(pending.length) : t("asBadgeOn"))
      : t("asBadgeOff");
    badge.className = "tag" + (snap.enabled ? (pending.length ? " tag--warn" : " tag--ok") : " tag--off");
  }
  var stats = el("as-stats");
  if (stats) {
    clear(stats);
    var mail = snap.mail || {};
    var enabledConnectors = (snap.connectors || []).filter(function (row) { return row.enabled; });
    stats.appendChild(statCard("asStatPending", String(pending.length), t("asStatPendingNote"), false));
    stats.appendChild(statCard("asStatDrafts", String((snap.drafts || []).length), t("asStatDraftsNote"), false));
    stats.appendChild(statCard("asStatConnectors", String(enabledConnectors.length), t("asStatConnectorsNote"), false));
    stats.appendChild(statCard("asStatMail",
      mail.imapStored && mail.smtpStored ? t("asMailReady") : t("asMailMissing"),
      String(mail.lastError || "").slice(0, 80), false));
  }
  setText("as-last-report", String(snap.lastReport || ""));
  setText("as-boundary", String(snap.boundary || ""));
  var pendingTag = el("as-pending-tag");
  if (pendingTag) {
    pendingTag.textContent = String(pending.length);
    pendingTag.className = "tag" + (pending.length ? " tag--warn" : "");
  }
  var auditTag = el("as-audit-tag");
  if (auditTag) { auditTag.textContent = String((snap.audit || []).length); }
}
function buildAssistantControls() {
  var host = el("as-switches"), fields = el("as-fields"), cfg = asConfig();
  if (!cfg) { return; }
  if (host) {
    clear(host);
    var box = h("div", { cls: "list" });
    box.appendChild(checkField("asMaster", function () { return cfg.enabled; },
      function (value) { cfg.enabled = value; renderAssistant(); }));
    box.appendChild(checkField("asBriefingSwitch", function () { return cfg.briefing.enabled; },
      function (value) { cfg.briefing.enabled = value; }));
    box.appendChild(checkField("asPatrolSwitch", function () { return cfg.patrol.enabled; },
      function (value) { cfg.patrol.enabled = value; }));
    box.appendChild(checkField("asMailSwitch", function () { return cfg.mail.enabled; },
      function (value) { cfg.mail.enabled = value; }));
    host.appendChild(box);
  }
  if (!fields) { return; }
  clear(fields);
  fields.appendChild(numField("asBriefHour", function () { return Number(cfg.briefing.hour) || 0; },
    function (value) { cfg.briefing.hour = value; }, 0, 23, t("asBriefHourNote")));
  fields.appendChild(numField("asBriefMinute", function () { return Number(cfg.briefing.minute) || 0; },
    function (value) { cfg.briefing.minute = value; }, 0, 59, t("asBriefMinuteNote")));
  fields.appendChild(numField("asPatrolInterval", function () { return Number(cfg.patrol.intervalMinutes) || 30; },
    function (value) { cfg.patrol.intervalMinutes = value; }, 5, 1440, t("asPatrolIntervalNote")));
  fields.appendChild(numField("asPatrolOffline", function () { return Number(cfg.patrol.offlineMinutes) || 15; },
    function (value) { cfg.patrol.offlineMinutes = value; }, 1, 240, t("asPatrolOfflineNote")));
  fields.appendChild(textField("asImapHost", function () { return cfg.mail.imapHost; },
    function (value) { cfg.mail.imapHost = value; }, null, "asImapHostNote"));
  fields.appendChild(numField("asImapPort", function () { return Number(cfg.mail.imapPort) || 993; },
    function (value) { cfg.mail.imapPort = value; }, 1, 65535, t("asPortNote")));
  fields.appendChild(textField("asSmtpHost", function () { return cfg.mail.smtpHost; },
    function (value) { cfg.mail.smtpHost = value; }, null, "asSmtpHostNote"));
  fields.appendChild(numField("asSmtpPort", function () { return Number(cfg.mail.smtpPort) || 465; },
    function (value) { cfg.mail.smtpPort = value; }, 1, 65535, t("asPortNote")));
  fields.appendChild(textField("asMailUser", function () { return cfg.mail.username; },
    function (value) { cfg.mail.username = value; }, null, "asMailUserNote"));
  fields.appendChild(textField("asMailFrom", function () { return cfg.mail.fromAddress; },
    function (value) { cfg.mail.fromAddress = value; }, null, "asMailFromNote"));
  fields.appendChild(numField("asLookback", function () { return Number(cfg.mail.lookbackDays) || 3; },
    function (value) { cfg.mail.lookbackDays = value; }, 1, 14, t("asLookbackNote")));
  fields.appendChild(numField("asMaxMessages", function () { return Number(cfg.mail.maxMessages) || 12; },
    function (value) { cfg.mail.maxMessages = value; }, 1, 30, t("asMaxMessagesNote")));
}
function renderAssistantConnectors() {
  var host = el("as-connectors"), rows = asSnap().connectors || [];
  if (!host) { return; }
  clear(host);
  if (!rows.length) { host.appendChild(h("div", { cls: "empty", text: t("asConnectorsIdle") })); return; }
  rows.forEach(function (row) {
    host.appendChild(h("div", { cls: "list__row" }, [
      h("span", { cls: "dot dot--" + (row.enabled ? (row.ready ? "ok" : "warn") : "off") }),
      h("span", { cls: "pv-line", text: asConnectorLabel(row.kind) }),
      pvTag(asPermLabel(row.permission), asPermKind(row.permission)),
      h("span", { cls: "pv-meta", text: String(row.detail || "") })
    ]));
  });
}
function renderAssistantRepairs() {
  var host = el("as-repairs"), cfg = asConfig();
  if (!host || !cfg) { return; }
  clear(host);
  cfg.repairs.forEach(function (rule, index) {
    var watch = h("input", { type: "text", spellcheck: "false", value: String(rule.watchEntity || ""), placeholder: "binary_sensor.gateway" });
    watch.addEventListener("input", function () { rule.watchEntity = watch.value; markDirty(); });
    var service = h("input", { type: "text", spellcheck: "false", value: String(rule.repairDomain || "") + "." + String(rule.repairService || ""), placeholder: "homeassistant.turn_on" });
    service.addEventListener("input", function () {
      var raw = service.value.trim();
      var dot = raw.indexOf(".");
      rule.repairDomain = dot > 0 ? raw.slice(0, dot) : "homeassistant";
      rule.repairService = dot > 0 ? raw.slice(dot + 1) : raw;
      markDirty();
    });
    var entity = h("input", { type: "text", spellcheck: "false", value: String(rule.repairEntity || ""), placeholder: "switch.gateway_power" });
    entity.addEventListener("input", function () { rule.repairEntity = entity.value; markDirty(); });
    var minutes = h("input", { type: "number", min: "1", max: "240", step: "1", value: String(Number(rule.offlineMinutes) || 15) });
    minutes.addEventListener("input", function () {
      var value = Math.max(1, Math.min(240, Math.round(Number(minutes.value) || 15)));
      rule.offlineMinutes = value;
      markDirty();
    });
    var on = h("input", { type: "checkbox" });
    on.checked = rule.enabled !== false;
    on.addEventListener("change", function () { rule.enabled = on.checked; markDirty(); });
    host.appendChild(h("div", { cls: "list__row" }, [
      watch, service, entity, minutes,
      h("label", { cls: "check" }, [on, h("span", { text: t("asRepairOn") })]),
      h("button", { cls: "btn btn--tiny", text: t("hvRemove"), type: "button", onclick: "PPX.asRemoveRepair(" + index + ")" })
    ]));
  });
  if (!cfg.repairs.length) { host.appendChild(note(t("asRepairsEmpty"))); }
  var add = el("as-addrepair");
  if (add) { add.classList.toggle("is-disabled", cfg.repairs.length >= AS_REPAIR_LIMIT); }
}
function renderAssistantCredentials() {
  var host = el("as-creds"), snap = asSnap(), mail = snap.mail || {};
  if (!host) { return; }
  clear(host);
  var rows = [
    ["imap", t("asCredImap"), Boolean(mail.imapStored), String(mail.imapPasswordRef || "")],
    ["smtp", t("asCredSmtp"), Boolean(mail.smtpStored), String(mail.smtpPasswordRef || "")]
  ];
  rows.forEach(function (row) {
    var input = h("input", { type: "password", spellcheck: "false", autocomplete: "off", placeholder: t("asCredPlaceholder") });
    var button = h("button", { cls: "btn btn--tiny", text: t("asCredStore"), type: "button" });
    button.addEventListener("click", function () { asStoreCredential(row[0], input, button); });
    host.appendChild(h("div", { cls: "list__row" }, [
      h("span", { cls: "pv-line", text: row[1] }),
      pvTag(row[2] ? t("asCredStored") : t("asCredMissing"), row[2] ? "ok" : "off"),
      h("span", { cls: "pv-meta mono", text: row[3] }),
      input,
      button
    ]));
  });
}
function asStoreCredential(kind, input, button) {
  var secret = String(input.value || "");
  if (!secret) { toast("warn", t("asCredEmpty")); return; }
  if (button) { button.classList.add("is-disabled"); }
  api(ROUTE.assistantMailCredential, { method: "POST", json: { kind: kind, secret: secret } }).then(function (reply) {
    input.value = "";
    if (button) { button.classList.remove("is-disabled"); }
    if (reply && reply.assistant) { S.snap.assistant = reply.assistant; }
    renderAssistant();
    renderAssistantCredentials();
    var ok = Boolean(reply && reply.ok);
    toast(ok ? "ok" : "err",
      String((reply && reply.detail) || t(ok ? "asCredStored" : "asCredFailed")) + " · " + String((reply && reply.reference) || ""));
    return refreshSnapshot(true);
  }).catch(function (error) {
    input.value = "";
    if (button) { button.classList.remove("is-disabled"); }
    fail("asCredFailed", error);
  });
}
function renderAssistantPending() {
  var host = el("as-pending"), cards = asSnap().pending || [];
  if (!host) { return; }
  clear(host);
  if (!cards.length) { host.appendChild(h("div", { cls: "empty", text: t("asPendingIdle") })); return; }
  cards.forEach(function (card) {
    var approve = h("button", { cls: "btn btn--mini", text: t("pvApprove"), type: "button" });
    approve.addEventListener("click", function () { asDecide(card.id, "approve"); });
    var reject = h("button", { cls: "btn btn--tiny", text: t("pvReject"), type: "button" });
    reject.addEventListener("click", function () { asDecide(card.id, "reject"); });
    if (!card.canApprove) { approve.classList.add("is-disabled"); }
    host.appendChild(h("div", { cls: "list__row" }, [
      h("span", { cls: "dot dot--warn" }),
      h("span", { cls: "pv-line", text: String(card.title || "") }),
      pvTag(String(card.kind || ""), "warn"),
      h("span", { cls: "pv-meta", text: String(card.target || "") }),
      h("span", { cls: "pv-meta mono", text: String(card.digest || "").slice(0, 24) }),
      h("span", { cls: "pv-meta", text: t("asTtl") + " " + String(card.secondsLeft || 0) + "s" }),
      approve, reject
    ]));
    if (card.detail) { host.appendChild(h("div", { cls: "pv-meta", text: String(card.detail).slice(0, 240) })); }
  });
}
function renderAssistantAudit() {
  var host = el("as-audit"), rows = asSnap().audit || [];
  if (!host) { return; }
  clear(host);
  if (!rows.length) { host.appendChild(h("div", { cls: "empty", text: t("asAuditIdle") })); return; }
  rows.forEach(function (row) {
    var outcome = String(row.outcome || "");
    host.appendChild(h("div", { cls: "list__row" }, [
      h("span", { cls: "pv-meta mono", text: pvWhen(row.at) }),
      h("span", { cls: "pv-line mono", text: String(row.event || "") }),
      pvTag(outcome, outcome === "ok" ? "ok" : outcome === "failed" ? "bad" : "warn"),
      h("span", { cls: "pv-meta", text: String(row.detail || "").slice(0, 160) })
    ]));
  });
}
function asRun(verb) {
  if (S.dirty) { toast("warn", t("asSaveFirst")); return; }
  if (!asSnap().enabled) { toast("warn", t("asSaveFirst")); return; }
  api(ROUTE.assistantControl, { method: "POST", json: { verb: verb } }).then(function (report) {
    if (report && report.assistant) { S.snap.assistant = report.assistant; }
    renderAssistant();
    renderAssistantConnectors();
    renderAssistantPending();
    renderAssistantAudit();
    var ok = Boolean(report && report.ok);
    toast(ok ? "ok" : "warn", String((report && report.detail) || t(ok ? "asRunDone" : "asRunFailed")));
    return refreshSnapshot(true);
  }).catch(function (error) { fail("asRunFailed", error); });
}
function asDecide(id, verb) {
  api(ROUTE.assistantDecision, { method: "POST", json: { id: id, verb: verb } }).then(function (report) {
    if (report && report.assistant) { S.snap.assistant = report.assistant; }
    renderAssistant();
    renderAssistantConnectors();
    renderAssistantPending();
    renderAssistantAudit();
    var ok = Boolean(report && report.ok);
    toast(ok ? "ok" : "err", String((report && report.detail) || t(ok ? "asDecisionDone" : "asDecisionFailed")));
    return refreshSnapshot(true);
  }).catch(function (error) { fail("asDecisionFailed", error); });
}
function asAddRepair() {
  var cfg = asConfig();
  if (!cfg) { return; }
  if (cfg.repairs.length >= AS_REPAIR_LIMIT) { toast("warn", t("asRepairsFull")); return; }
  cfg.repairs.push({
    watchEntity: "", repairEntity: "", repairDomain: "homeassistant",
    repairService: "turn_on", offlineMinutes: 15, enabled: true
  });
  markDirty();
  renderAssistantRepairs();
}
function asRemoveRepair(index) {
  var cfg = asConfig();
  if (!cfg) { return; }
  cfg.repairs.splice(index, 1);
  markDirty();
  renderAssistantRepairs();
}

function renderStep5() {
  ensureForm(S.snap);
  renderHubStats();
  renderDiscovery();
  buildHubControls();
  renderHubEntityRows();
  renderHubTargetRows();
  renderHubStatus();
  renderHubProposals();
  renderUpdatePanel();
  buildUpdateControls();
  renderDiscoverPanel();
  buildDiscoverControls();
  renderDiscoverSources();
  renderGodsEye();
  buildGodsEyeControls();
  renderGodsEyeCredentials();
  renderAssistant();
  buildAssistantControls();
  renderAssistantConnectors();
  renderAssistantRepairs();
  renderAssistantCredentials();
  renderAssistantPending();
  renderAssistantAudit();
  renderSaveBar();
}
function renderHubStats() {
  var disc = S.discovery || {}, slot = el("hv-stats");
  if (!slot) { return; }
  clear(slot);
  var caps = disc.capabilities || [];
  slot.appendChild(statCard("hvStatCaps", String(caps.length), "", false));
  var refused = caps.filter(function (row) { return row.state === "refused"; }).length;
  slot.appendChild(statCard("hvStatRefused", String(refused), t("hvStatRefusedNote"), false));
  var hub = S.hub || {};
  var mcp = (hub.mcp && hub.mcp.data) || {};
  slot.appendChild(statCard("hvStatServers", String(mcp.serverCount || 0) + " · " + String(mcp.connectedCount || 0),
    t("hvStatServersNote"), false));
  var home = ((hub.home && hub.home.data) || {});
  slot.appendChild(statCard("hvStatEntities", String(home.entityCount || 0),
    t("hvStatEntitiesNote"), false));
  var badge = el("hv-badge");
  if (badge) {
    var pending = hvPendingCards().length;
    badge.textContent = pending ? t("hvBadgePending") + " " + String(pending)
      : hvAnyOn() ? t("hvBadgeOn") : t("hvBadgeOff");
    badge.className = "tag" + (pending ? " tag--warn" : hvAnyOn() ? " tag--ok" : " tag--off");
  }
  var tag = el("hv-prop-tag");
  if (tag) {
    var count = hvPendingCards().length;
    tag.textContent = String(count);
    tag.className = "tag" + (count ? " tag--warn" : "");
  }
}
function renderDiscovery() {
  var host = el("hv-caps"), tag = el("hv-disc-tag"), bound = el("hv-bound");
  var disc = S.discovery || {}, caps = disc.capabilities || [];
  if (tag) {
    tag.textContent = disc.scanning ? t("hvScanning") : caps.length ? String(caps.length) : t("hvDiscIdle");
    tag.className = "tag" + (disc.scanning ? " tag--warn" : "");
  }
  if (bound) {
    bound.textContent = String(disc.boundary || t("hvBoundary"))
      + (disc.scannedAt ? " · " + pvWhen(disc.scannedAt) : "");
  }
  if (!host) { return; }
  clear(host);
  if (!caps.length) { host.appendChild(h("div", { cls: "empty", text: t("hvDiscIdle") })); return; }
  caps.forEach(function (row) {
    var box = h("div", { cls: "list__row" }, [
      h("span", { cls: "dot dot--" + hvStateKind(row.state) }),
      h("span", { cls: "pv-line", text: String(row.label || "") }),
      pvTag(hvKindLabel(row.kind)),
      pvTag(hvStateLabel(row.state), hvStateKind(row.state))
    ]);
    host.appendChild(box);
    if (row.detail) { host.appendChild(h("div", { cls: "pv-meta", text: String(row.detail).slice(0, 240) })); }
    if (row.origin) { host.appendChild(h("div", { cls: "pv-meta mono", text: String(row.origin) })); }
  });
}
function buildHubControls() {
  var host = el("hv-switches"), fields = el("hv-fields"), cfg = hvConfig();
  if (!cfg) { return; }
  if (host) {
    clear(host);
    var box = h("div", { cls: "list" });
    box.appendChild(checkField("hvMcpSwitch", function () { return cfg.allowMcpBridge; },
      function (value) { cfg.allowMcpBridge = value; }));
    box.appendChild(checkField("hvHomeSwitch", function () { return cfg.allowSmartHomeBridge; },
      function (value) { cfg.allowSmartHomeBridge = value; }));
    box.appendChild(checkField("hvCalDavSwitch", function () { return cfg.allowCalDavBridge; },
      function (value) { cfg.allowCalDavBridge = value; }));
    box.appendChild(checkField("hvAutoScan", function () { return cfg.discovery.autoScanOnLaunch; },
      function (value) { cfg.discovery.autoScanOnLaunch = value; }));
    box.appendChild(checkField("hvReadonly", function () { return cfg.smartHome.readOnlyMode; },
      function (value) { cfg.smartHome.readOnlyMode = value; }));
    box.appendChild(checkField("hvTelemetry", function () { return cfg.smartHome.allowMqttTelemetry; },
      function (value) { cfg.smartHome.allowMqttTelemetry = value; }));
    host.appendChild(box);
  }
  if (fields) {
    clear(fields);
    fields.appendChild(urlField("hvHaUrl", function () { return cfg.smartHome.homeAssistantUrl; },
      function (value) { cfg.smartHome.homeAssistantUrl = value; }, "http://homeassistant.local:8123", "hvHaNote"));
    fields.appendChild(secretField("hvHaToken", function () { return ""; }, function (value) {
      hvDraftToken("homeToken", value);
    }));
    fields.appendChild(textField("hvMqttHost", function () { return cfg.smartHome.mqttHost; },
      function (value) { cfg.smartHome.mqttHost = value; }, "hvMqttHostPlaceholder", "hvMqttNote"));
    fields.appendChild(numField("hvMqttPort", function () { return Number(cfg.smartHome.mqttPort) || 1883; },
      function (value) { cfg.smartHome.mqttPort = value; }, 1, 65535, null));
    fields.appendChild(secretField("hvMqttPassword", function () { return ""; }, function (value) {
      hvDraftToken("mqttPassword", value);
    }));
    var store = h("div", { cls: "btn-row" }, [
      h("button", { cls: "btn btn--mini", type: "button", text: t("hvSecretSave"), onclick: "PPX.hvStoreHome()" })
    ]);
    fields.appendChild(store);
    fields.appendChild(h("hr", { cls: "hair" }));
    var calId = h("input", { type: "text", spellcheck: "false", id: "hv-caldav-id", placeholder: "icloud" });
    calId.addEventListener("input", function () { hvDraftCalDavId(calId.value); });
    fields.appendChild(fieldWrap("hvCalDavId", calId, note(t("hvCalDavIdNote"))));
    var calSecret = h("input", { type: "password", spellcheck: "false", id: "hv-caldav-secret", autocomplete: "off" });
    fields.appendChild(fieldWrap("hvCalDavPassword", calSecret, note(t("hvCalDavPasswordNote"))));
    fields.appendChild(h("div", { cls: "btn-row" }, [
      h("button", { cls: "btn btn--mini", type: "button", text: t("hvSecretSave"), onclick: "PPX.hvStoreCalDav()" })
    ]));
  }
}
/* A typed credential is held only in this closure until the 「存入钥匙串」 click posts it. It is
   deliberately not copied into `S.form`, so a 「保存」 of the settings document cannot put it in a
   file, and a page reload drops it. */
var HV_DRAFT = { homeToken: "", mqttPassword: "", calDavId: "" };
function hvDraftToken(kind, value) { HV_DRAFT[kind] = value; }
function hvDraftCalDavId(value) { HV_DRAFT.calDavId = value; }
function renderHubEntityRows() {
  var host = el("hv-entities"), cfg = hvConfig();
  if (!host || !cfg) { return; }
  clear(host);
  var list = cfg.smartHome.exposedEntities;
  list.forEach(function (item, index) {
    var input = h("input", { type: "text", spellcheck: "false", value: String(item), placeholder: "light.study_desk" });
    input.addEventListener("input", function () { list[index] = input.value; markDirty(); });
    host.appendChild(h("div", { cls: "list__row" }, [
      input,
      h("button", { cls: "btn btn--tiny", text: t("hvRemove"), type: "button", onclick: "PPX.hvRemoveEntity(" + index + ")" })
    ]));
  });
  if (!list.length) { host.appendChild(note(t("hvEntityEmpty"))); }
  var add = el("hv-addentity");
  if (add) { add.classList.toggle("is-disabled", list.length >= HV_ENTITY_LIMIT); }
}
function renderHubTargetRows() {
  var host = el("hv-targets"), cfg = hvConfig();
  if (!host || !cfg) { return; }
  clear(host);
  var list = cfg.discovery.lanTargets;
  list.forEach(function (item, index) {
    var input = h("input", { type: "text", spellcheck: "false", value: String(item), placeholder: "homeassistant.local:8123" });
    input.addEventListener("input", function () { list[index] = input.value; markDirty(); });
    host.appendChild(h("div", { cls: "list__row" }, [
      input,
      h("button", { cls: "btn btn--tiny", text: t("hvRemove"), type: "button", onclick: "PPX.hvRemoveTarget(" + index + ")" })
    ]));
  });
  if (!list.length) { host.appendChild(note(t("hvTargetEmpty"))); }
  var add = el("hv-addtarget");
  if (add) { add.classList.toggle("is-disabled", list.length >= HV_TARGET_LIMIT); }
}
function renderHubStatus() {
  var host = el("hv-status");
  if (!host) { return; }
  clear(host);
  var rows = [
    ["mcp", t("hvBridgeMCP")],
    ["home", t("hvBridgeHome")],
    ["calDav", t("hvBridgeCalDav")]
  ];
  rows.forEach(function (row) {
    var entry = (S.hub || {})[row[0]];
    if (!entry) {
      host.appendChild(h("div", { cls: "list__row" }, [
        h("span", { cls: "dot" }),
        h("span", { cls: "pv-line", text: row[1] }),
        pvTag(S.hubPending ? t("hvChecking") : t("hvStatusIdle"), "off")
      ]));
      return;
    }
    if (!entry.ok) {
      host.appendChild(h("div", { cls: "list__row" }, [
        h("span", { cls: "dot dot--bad" }),
        h("span", { cls: "pv-line", text: row[1] }),
        pvTag(t("hvStateOff"), "off")
      ]));
      host.appendChild(h("div", { cls: "pv-meta", text: String(entry.message || "").slice(0, 240) }));
      return;
    }
    var data = entry.data || {};
    host.appendChild(h("div", { cls: "list__row" }, [
      h("span", { cls: "dot dot--ok" }),
      h("span", { cls: "pv-line", text: row[1] }),
      pvTag(hvBridgeSummary(row[0], data), "ok")
    ]));
    (data.servers || data.entities || []).slice(0, 6).forEach(function (card) {
      host.appendChild(h("div", { cls: "pv-meta", text: hvCardLine(row[0], card) }));
    });
    if (data.gate) { host.appendChild(h("div", { cls: "pv-meta", text: String(data.gate) })); }
    if (data.redaction) { host.appendChild(h("div", { cls: "pv-meta", text: String(data.redaction) })); }
    if (row[0] === "mcp" && (data.entryRejections || []).length) {
      host.appendChild(h("div", { cls: "pv-meta", text: t("hvRejectedEntries") + " " + String(data.entryRejections.length) }));
    }
  });
}
/* One `t()` per bridge rather than a table, so a missing label is a visible empty string the
   catalog gate can catch instead of a row that silently renders English. */
function hvBridgeSummary(kind, data) {
  if (kind === "mcp") {
    return String(data.serverCount || 0) + " · " + String(data.connectedCount || 0) + " · " + String(data.toolCount || 0);
  }
  if (kind === "home") {
    var status = data.status || {};
    return String(status.homeAssistantConfigured ? t("hvHaOk") : t("hvHaAbsent")) + " · "
      + String(status.mqttConnected ? t("hvMqttOk") : t("hvMqttAbsent"));
  }
  return String(data.busyCount || 0) + " · " + String(data.busyMinutes || 0) + " · " + String(data.serverCount || 0);
}
function hvCardLine(kind, card) {
  if (kind === "home") { return String(card.entityID || "") + " · " + String(card.state || ""); }
  return String(card.id || card.label || "") + " · "
    + (card.connected === undefined ? "" : String(card.connected)) + " · "
    + String(card.reason || card.detail || "");
}
function renderHubProposals() {
  var host = el("hv-proposals");
  if (!host) { return; }
  clear(host);
  var cards = hvPendingCards();
  if (!cards.length) { host.appendChild(h("div", { cls: "empty", text: t("hvPropNone") })); return; }
  cards.forEach(function (card) { host.appendChild(pvProposalCard(card)); });
}

function hvStore(kind, field) {
  var input = el(field);
  if (!input) { return; }
  var secret = String(input.value || "");
  HV_DRAFT[kind] = "";
  if (!secret) { toast("warn", t("hvSecretEmpty")); return; }
  var server = kind === "calDav" ? String(HV_DRAFT.calDavId || "") : "";
  if (kind === "calDav" && !server) { toast("warn", t("hvServerRequired")); return; }
  api(ROUTE.hubCredential, { method: "POST", json: { bridge: kind, serverId: server, secret: secret } })
    .then(function (reply) {
      input.value = "";
      toast("ok", t("hvSecretStored") + " · " + String((reply && reply.reference) || ""));
      // The node wrote the reference into the settings document, so the page adopts what
      // it says rather than guessing where the reference belongs.
      refreshSnapshot(true);
      hvStatus();
    })
    .catch(function (error) { input.value = ""; fail("hvSecretFailed", error); });
}
function hvStoreHome() {
  var wrote = false;
  if (HV_DRAFT.homeToken) { hvStore("homeToken", "hvHaToken"); wrote = true; }
  if (HV_DRAFT.mqttPassword) { hvStore("mqttPassword", "hvMqttPassword"); wrote = true; }
  if (!wrote) { toast("warn", t("hvSecretEmpty")); }
}
function hvStoreCalDav() {
  hvStore("calDav", "hv-caldav-secret");
}
function hvAddEntity() {
  var cfg = hvConfig();
  if (!cfg) { return; }
  if (cfg.smartHome.exposedEntities.length >= HV_ENTITY_LIMIT) { toast("warn", t("hvEntityLimit")); return; }
  cfg.smartHome.exposedEntities.push("");
  markDirty();
  renderHubEntityRows();
}
function hvRemoveEntity(index) {
  var cfg = hvConfig();
  if (!cfg) { return; }
  cfg.smartHome.exposedEntities.splice(index, 1);
  markDirty();
  renderHubEntityRows();
}
function hvAddTarget() {
  var cfg = hvConfig();
  if (!cfg) { return; }
  if (cfg.discovery.lanTargets.length >= HV_TARGET_LIMIT) { toast("warn", t("hvTargetLimit")); return; }
  cfg.discovery.lanTargets.push("");
  markDirty();
  renderHubTargetRows();
}
function hvRemoveTarget(index) {
  var cfg = hvConfig();
  if (!cfg) { return; }
  cfg.discovery.lanTargets.splice(index, 1);
  markDirty();
  renderHubTargetRows();
}

/* ------------------------------------------ signed updates & discover feed */
/* The update feed is the node's, not the page's. The manifest URL and public key are
   typed here and stored in the settings document; the console never receives a receipt,
   because the route mints it inside the node from the click itself. The four ceilings
   are the node's numbers (`DiscoverConfig`), copied here so the page refuses to add a
   row the node would silently drop. */
var DC_FOLDER_LIMIT = 4;
var DC_FEED_LIMIT = 8;
var DC_MCP_LIMIT = 4;
function upSaved() { return (S.snap && S.snap.settings && S.snap.settings.updates) || {}; }
function upConfig() {
  if (!S.form) { return null; }
  if (!S.form.updates) { S.form.updates = clone(upSaved()); }
  var cfg = S.form.updates;
  cfg.packageHosts = cfg.packageHosts || [];
  if (cfg.intervalMinutes === undefined) { cfg.intervalMinutes = 360; }
  if (cfg.snoozeHours === undefined) { cfg.snoozeHours = 24; }
  return cfg;
}
function upSnap() { return (S.snap && S.snap.update) || {}; }
function dcSaved() { return (S.snap && S.snap.settings && S.snap.settings.discover) || {}; }
function dcConfig() {
  if (!S.form) { return null; }
  if (!S.form.discover) { S.form.discover = clone(dcSaved()); }
  var cfg = S.form.discover;
  cfg.folders = cfg.folders || [];
  cfg.feeds = cfg.feeds || [];
  cfg.mcpSources = cfg.mcpSources || [];
  if (cfg.intervalMinutes === undefined) { cfg.intervalMinutes = 60; }
  if (cfg.maxItems === undefined) { cfg.maxItems = 20; }
  return cfg;
}
function dcSnap() { return (S.snap && S.snap.discover) || {}; }

function renderUpdatePanel() {
  var upd = upSnap(), release = upd.available;
  var badge = el("up-badge");
  if (badge) {
    badge.textContent = release ? t("upBadgeReady") + " " + String(release.version || "")
      : upd.enabled ? (upd.usable ? t("upBadgeOn") : t("upBadgeIncomplete")) : t("upBadgeOff");
    badge.className = "tag" + (release ? " tag--warn" : upd.enabled && upd.usable ? " tag--ok" : " tag--off");
  }
  var stats = el("up-stats");
  if (stats) {
    clear(stats);
    stats.appendChild(statCard("upCurrent", String(upd.currentVersion || "—"),
      upd.installedVersion ? t("upInstalled") + " " + String(upd.installedVersion) : "", true));
    stats.appendChild(statCard("upKey", String(upd.keyFingerprint || "—"), String(upd.manifestHost || ""), true));
    stats.appendChild(statCard("upLastCheck", upd.lastCheckAt ? pvWhen(upd.lastCheckAt) : t("never"), "", true));
  }
  var bound = el("up-bound");
  if (bound) {
    var lines = [String(upd.boundary || "")];
    if (upd.lastIgnored) { lines.push(t("upIgnored") + " · " + String(upd.lastIgnored)); }
    if (upd.lastError) { lines.push(String(upd.lastError)); }
    bound.textContent = lines.filter(function (line) { return line.length; }).join(" · ");
  }
  var host = el("up-pending");
  if (host) {
    clear(host);
    if (!release) { host.appendChild(h("div", { cls: "empty", text: t("upNoPending") })); }
    else { host.appendChild(upPendingCard(upd, release)); }
  }
  var check = el("up-check");
  if (check && !check.dataset.busy) { check.textContent = t("upCheck"); }
}
function upPendingCard(upd, release) {
  var pkg = release.package || {};
  var box = h("div", { cls: "pv-card is-live" });
  box.appendChild(h("div", { cls: "pv-top" }, [
    h("span", { cls: "pv-title", text: String(release.version || "") }),
    pvTag(t("upPendingTitle"), "warn"),
    upd.snoozedUntil ? pvTag(t("upSnooze") + " · " + pvWhen(upd.snoozedUntil), "off") : null
  ]));
  var meta = [];
  if (release.build) { meta.push(t("upBuild") + " " + String(release.build)); }
  if (release.releasedAt) { meta.push(t("upReleased") + " " + String(release.releasedAt)); }
  if (pkg.sha256) { meta.push(t("upPackage") + " " + String(pkg.sha256).slice(0, 12) + " · " + bytes(pkg.size)); }
  if (meta.length) { box.appendChild(h("div", { cls: "pv-meta", text: meta.join("  ·  ") })); }
  var summary = release.summary || [];
  if (summary.length) {
    box.appendChild(h("div", { cls: "pv-meta", text: t("upSummary") }));
    summary.slice(0, 8).forEach(function (line) {
      box.appendChild(h("div", { cls: "pv-line", text: String(line).slice(0, 200) }));
    });
  }
  var acts = h("div", { cls: "pv-acts" });
  ["approve", "snooze"].forEach(function (verb) {
    acts.appendChild(h("button", {
      cls: "btn btn--mini " + (verb === "approve" ? "btn--ok" : "btn--ghost"),
      text: verb === "approve" ? t("upApprove") : t("upSnooze"),
      type: "button",
      onclick: "PPX.upDecide(this, '" + verb + "')"
    }));
  });
  box.appendChild(acts);
  return box;
}
function buildUpdateControls() {
  var host = el("up-switch"), fields = el("up-fields"), cfg = upConfig();
  if (!cfg) { return; }
  if (host) {
    clear(host);
    host.appendChild(checkField("upEnabled", function () { return cfg.enabled; },
      function (value) { cfg.enabled = value; }));
  }
  if (!fields) { return; }
  clear(fields);
  fields.appendChild(urlField("upManifestURL", function () { return cfg.manifestURL; },
    function (value) { cfg.manifestURL = value; }, "https://downloads.popopx.chat/manifest.json", "upManifestNote"));
  fields.appendChild(textField("upPublicKey", function () { return cfg.publicKey; },
    function (value) { cfg.publicKey = value; }, null, "upKeyNote"));
  var hosts = h("input", {
    type: "text", spellcheck: "false",
    value: String((cfg.packageHosts || []).join(", ")), placeholder: "cdn.popopx.chat"
  });
  hosts.addEventListener("input", function () {
    cfg.packageHosts = hosts.value.split(",")
      .map(function (part) { return part.trim(); })
      .filter(function (part) { return part.length; });
    markDirty();
  });
  fields.appendChild(fieldWrap("upPackageHosts", hosts, note(t("upPackageNote"))));
  fields.appendChild(numField("upInterval", function () { return cfg.intervalMinutes || 360; },
    function (value) { cfg.intervalMinutes = value; }, 15, 10080, null));
  fields.appendChild(numField("upSnoozeHours", function () { return cfg.snoozeHours || 24; },
    function (value) { cfg.snoozeHours = value; }, 1, 168, null));
}

function renderDiscoverPanel() {
  var disc = dcSnap();
  var tag = el("dc-feed-tag");
  if (tag) { tag.textContent = String(disc.itemCount || 0); }
  var badge = el("dc-badge");
  if (badge) {
    badge.textContent = disc.enabled ? t("dcBadgeOn") : t("dcBadgeOff");
    badge.className = "tag" + (disc.enabled ? " tag--ok" : " tag--off");
  }
  var stats = el("dc-stats");
  if (stats) {
    clear(stats);
    stats.appendChild(statCard("dcStatItems", String(disc.itemCount || 0), "", false));
    stats.appendChild(statCard("dcStatSources", String((disc.sources || []).length), "", true));
    stats.appendChild(statCard("dcStatLastRun", disc.lastRunAt ? pvWhen(disc.lastRunAt) : t("never"), "", true));
    stats.appendChild(statCard("dcStatDelivered", disc.lastDeliveredAt ? pvWhen(disc.lastDeliveredAt) : t("never"), "", true));
  }
  var host = el("dc-list");
  if (!host) { return; }
  clear(host);
  var items = disc.items || [];
  if (!items.length) {
    host.appendChild(h("div", { cls: "empty", text: disc.lastError ? String(disc.lastError) : t("dcEmpty") }));
    return;
  }
  items.forEach(function (item) {
    host.appendChild(h("div", { cls: "pv-card" }, [
      h("div", { cls: "pv-top" }, [
        h("span", { cls: "pv-title", text: String(item.title || "—").slice(0, 160) }),
        pvTag(String(item.sourceLabel || ""), "accent")
      ]),
      item.summary ? h("div", { cls: "pv-line", text: String(item.summary).slice(0, 240) }) : null,
      h("div", { cls: "pv-meta mono", text: String(item.timestamp || "") })
    ]));
  });
}
function dcKindLabel(kind) {
  if (kind === "folder") { return t("dcKindFolder"); }
  if (kind === "json") { return t("dcKindJSON"); }
  if (kind === "mcp") { return t("dcKindMCP"); }
  if (kind === "rss") { return t("dcKindRSS"); }
  return String(kind || "—");
}
function dcStateLabel(state) {
  if (state === "ok") { return t("dcStateOk"); }
  if (state === "refused") { return t("dcStateRefused"); }
  if (state === "failed") { return t("dcStateFailed"); }
  return t("dcStateOff");
}
function dcStateKind(state) {
  if (state === "ok") { return "ok"; }
  if (state === "refused" || state === "failed") { return "bad"; }
  return "off";
}
function renderDiscoverSources() {
  var host = el("dc-sources"), tag = el("dc-src-tag"), disc = dcSnap();
  var sources = disc.sources || [];
  if (tag) { tag.textContent = String(sources.length); }
  if (!host) { return; }
  clear(host);
  if (!sources.length) { host.appendChild(h("div", { cls: "empty", text: t("dcSourcesIdle") })); return; }
  sources.forEach(function (row) {
    var state = String(row.state || "off");
    host.appendChild(h("div", { cls: "list__row" }, [
      h("span", { cls: "dot dot--" + dcStateKind(state) }),
      h("span", { cls: "pv-line", text: String(row.label || row.id || "") }),
      pvTag(dcKindLabel(row.kind), "accent"),
      pvTag(dcStateLabel(state), state === "ok" ? "ok" : state === "off" ? "off" : "bad")
    ]));
    if (row.detail) { host.appendChild(h("div", { cls: "pv-meta", text: String(row.detail).slice(0, 240) })); }
    host.appendChild(h("div", { cls: "pv-meta", text: t("dcStatItems") + " " + String(row.itemCount || 0) }));
  });
}
function buildDiscoverControls() {
  var host = el("dc-switch"), fields = el("dc-fields"), cfg = dcConfig();
  if (!cfg) { return; }
  if (host) {
    clear(host);
    host.appendChild(checkField("dcEnabled", function () { return cfg.enabled; },
      function (value) { cfg.enabled = value; }));
  }
  if (fields) {
    clear(fields);
    fields.appendChild(numField("dcInterval", function () { return cfg.intervalMinutes || 60; },
      function (value) { cfg.intervalMinutes = value; }, 15, 1440, null));
    fields.appendChild(numField("dcMaxItems", function () { return cfg.maxItems || 20; },
      function (value) { cfg.maxItems = value; }, 1, 60, null));
  }
  renderDiscoverFolders();
  renderDiscoverFeeds();
  renderDiscoverMCP();
}
function renderDiscoverFolders() {
  var host = el("dc-folders"), cfg = dcConfig();
  if (!host || !cfg) { return; }
  clear(host);
  cfg.folders.forEach(function (item, index) {
    var input = h("input", { type: "text", spellcheck: "false", value: String(item), placeholder: "~/Documents/notes" });
    input.addEventListener("input", function () { cfg.folders[index] = input.value; markDirty(); });
    host.appendChild(h("div", { cls: "list__row" }, [
      input,
      h("button", { cls: "btn btn--tiny", text: t("hvRemove"), type: "button", onclick: "PPX.dcRemoveFolder(" + index + ")" })
    ]));
  });
  if (!cfg.folders.length) { host.appendChild(note(t("dcFolderEmpty"))); }
  var add = el("dc-folder-add");
  if (add) { add.classList.toggle("is-disabled", cfg.folders.length >= DC_FOLDER_LIMIT); }
}
function renderDiscoverFeeds() {
  var host = el("dc-feeds"), cfg = dcConfig();
  if (!host || !cfg) { return; }
  clear(host);
  cfg.feeds.forEach(function (item, index) {
    var label = h("input", { type: "text", spellcheck: "false", value: String(item.label || ""), placeholder: t("dcLabel") });
    label.addEventListener("input", function () { item.label = label.value; markDirty(); });
    var url = h("input", {
      type: "text", spellcheck: "false", value: String(item.url || ""),
      placeholder: "http://192.168.1.10:8080/feed.xml", inputmode: "url"
    });
    url.addEventListener("input", function () { item.url = url.value; markDirty(); });
    var kind = h("select");
    [["rss", t("dcKindRSS")], ["json", t("dcKindJSON")]].forEach(function (pair) {
      kind.appendChild(h("option", { value: pair[0], text: pair[1] }));
    });
    kind.value = item.kind === "json" ? "json" : "rss";
    kind.addEventListener("change", function () { item.kind = kind.value; markDirty(); });
    var enabled = h("input", { type: "checkbox" });
    enabled.checked = item.enabled !== false;
    enabled.addEventListener("change", function () { item.enabled = enabled.checked; markDirty(); });
    host.appendChild(h("div", { cls: "list__row" }, [
      label, url, kind,
      h("label", { cls: "check" }, [enabled, h("span", { text: t("dcFeedOn") })]),
      h("button", { cls: "btn btn--tiny", text: t("hvRemove"), type: "button", onclick: "PPX.dcRemoveFeed(" + index + ")" })
    ]));
  });
  if (!cfg.feeds.length) { host.appendChild(note(t("dcFeedEmpty"))); }
  var add = el("dc-feed-add");
  if (add) { add.classList.toggle("is-disabled", cfg.feeds.length >= DC_FEED_LIMIT); }
}
function renderDiscoverMCP() {
  var host = el("dc-mcp"), cfg = dcConfig();
  if (!host || !cfg) { return; }
  clear(host);
  cfg.mcpSources.forEach(function (item, index) {
    var label = h("input", { type: "text", spellcheck: "false", value: String(item.label || ""), placeholder: t("dcLabel") });
    label.addEventListener("input", function () { item.label = label.value; markDirty(); });
    var server = h("input", { type: "text", spellcheck: "false", value: String(item.serverID || ""), placeholder: "notes" });
    server.addEventListener("input", function () { item.serverID = server.value; markDirty(); });
    var tool = h("input", { type: "text", spellcheck: "false", value: String(item.toolName || ""), placeholder: "search" });
    tool.addEventListener("input", function () { item.toolName = tool.value; markDirty(); });
    var args = h("input", {
      type: "text", spellcheck: "false", placeholder: "{}",
      value: JSON.stringify(item.arguments || {})
    });
    args.addEventListener("input", function () {
      try {
        var parsed = JSON.parse(args.value || "{}");
        if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
          item.arguments = parsed;
          markDirty();
        }
      } catch (ignored) { /* an unfinished fragment keeps the last valid object */ }
    });
    host.appendChild(h("div", { cls: "list__row" }, [
      label, server, tool, args,
      h("button", { cls: "btn btn--tiny", text: t("hvRemove"), type: "button", onclick: "PPX.dcRemoveMcp(" + index + ")" })
    ]));
  });
  if (!cfg.mcpSources.length) { host.appendChild(note(t("dcMcpEmpty"))); }
  var add = el("dc-mcp-add");
  if (add) { add.classList.toggle("is-disabled", cfg.mcpSources.length >= DC_MCP_LIMIT); }
}
function dcAddFolder() {
  var cfg = dcConfig();
  if (!cfg) { return; }
  if (cfg.folders.length >= DC_FOLDER_LIMIT) { toast("warn", t("dcFolderLimit")); return; }
  cfg.folders.push("");
  markDirty();
  renderDiscoverFolders();
}
function dcRemoveFolder(index) {
  var cfg = dcConfig();
  if (!cfg) { return; }
  cfg.folders.splice(index, 1);
  markDirty();
  renderDiscoverFolders();
}
function dcAddFeed() {
  var cfg = dcConfig();
  if (!cfg) { return; }
  if (cfg.feeds.length >= DC_FEED_LIMIT) { toast("warn", t("dcFeedLimit")); return; }
  cfg.feeds.push({ id: "", label: "", url: "", kind: "rss", enabled: true });
  markDirty();
  renderDiscoverFeeds();
}
function dcRemoveFeed(index) {
  var cfg = dcConfig();
  if (!cfg) { return; }
  cfg.feeds.splice(index, 1);
  markDirty();
  renderDiscoverFeeds();
}
function dcAddMcp() {
  var cfg = dcConfig();
  if (!cfg) { return; }
  if (cfg.mcpSources.length >= DC_MCP_LIMIT) { toast("warn", t("dcMcpLimit")); return; }
  cfg.mcpSources.push({ id: "", label: "", serverID: "", toolName: "", arguments: {}, enabled: true });
  markDirty();
  renderDiscoverMCP();
}
function dcRemoveMcp(index) {
  var cfg = dcConfig();
  if (!cfg) { return; }
  cfg.mcpSources.splice(index, 1);
  markDirty();
  renderDiscoverMCP();
}
function upActionLabel(verb) { return verb === "approve" ? t("upApprove") : t("upSnooze"); }
function upDisarm(button, verb) {
  button.dataset.armed = "";
  button.classList.remove("is-arm");
  button.textContent = upActionLabel(verb);
}
function upDecide(button, verb) {
  if (button.dataset.armed === "1") {
    upDisarm(button, verb);
    postUpdateDecision(verb, button);
    return;
  }
  button.dataset.armed = "1";
  button.classList.add("is-arm");
  button.textContent = t("upConfirmAgain");
  window.setTimeout(function () {
    if (button.dataset.armed === "1" && button.isConnected) { upDisarm(button, verb); }
  }, 8000);
}
function postUpdateDecision(verb, button) {
  if (button) { button.classList.add("is-disabled"); }
  api(ROUTE.updateDecision, { method: "POST", json: { verb: verb } }).then(function (report) {
    if (report && report.update) { S.snap.update = report.update; }
    renderUpdatePanel();
    var ok = Boolean(report && report.ok);
    toast(ok ? "ok" : "err", String((report && report.detail) || t(ok ? "upDone" : "upRefused")));
    refreshSnapshot(true);
  }).catch(function (error) {
    if (button) { button.classList.remove("is-disabled"); }
    fail("upFailed", error);
  });
}
function upCheck() {
  var button = el("up-check");
  if (button) {
    button.dataset.busy = "1";
    button.classList.add("is-disabled");
    button.textContent = t("upChecking");
  }
  function done() {
    if (!button) { return; }
    button.dataset.busy = "";
    button.classList.remove("is-disabled");
    button.textContent = t("upCheck");
  }
  api(ROUTE.updateCheck, { method: "POST", json: {} }).then(function (report) {
    done();
    if (report && report.update) { S.snap.update = report.update; }
    renderUpdatePanel();
    var outcome = String((report && report.outcome) || "failed");
    if (outcome === "available") { toast("ok", t("upFound") + " · " + String(report.detail || "")); }
    else if (outcome === "failed") { toast("err", String((report && report.detail) || t("upCheckFailed"))); }
    else if (outcome === "ignored") { toast("warn", String((report && report.detail) || t("upIgnored"))); }
    else if (outcome === "disabled") { toast("warn", String((report && report.detail) || t("upBadgeOff"))); }
    else { toast("ok", t("upUpToDate")); }
    refreshSnapshot(true);
  }).catch(function (error) { done(); fail("upCheckFailed", error); });
}
function dcRefresh() {
  var button = el("dc-refresh");
  if (button) {
    button.classList.add("is-disabled");
    button.textContent = t("dcRefreshing");
  }
  function done() {
    if (!button) { return; }
    button.classList.remove("is-disabled");
    button.textContent = t("dcRefresh");
  }
  api(ROUTE.discoverRefresh, { method: "POST", json: {} }).then(function (report) {
    done();
    if (report && report.discover) { S.snap.discover = report.discover; }
    renderDiscoverPanel();
    renderDiscoverSources();
    var outcome = String((report && report.outcome) || "failed");
    var detail = String((report && report.detail) || outcome);
    toast(outcome === "failed" ? "err" : "ok",
      detail + (report && report.itemCount ? " · " + String(report.itemCount) : ""));
    refreshSnapshot(true);
  }).catch(function (error) { done(); fail("dcRefreshFailed", error); });
}

/* ---------------------------------------------------------------- decisions */
/* The confirmation gate is two clicks and one request. The first click only arms the
   button; the second posts. The node then mints the receipt for that exact id and verb,
   so a click cannot be replayed against another proposal, and a page that is merely open
   writes nothing by itself. */
function pvDecide(node) {
  if (node.dataset.armed === "1") {
    disarmPv(node);
    postDecision(node.dataset.domain, node.dataset.id, node.dataset.verb);
    return;
  }
  node.dataset.armed = "1";
  node.classList.add("is-arm");
  node.textContent = t("pvConfirmAgain");
  window.setTimeout(function () {
    if (node.dataset.armed === "1" && node.isConnected) { disarmPv(node); }
  }, 8000);
}
function disarmPv(node) {
  node.dataset.armed = "0";
  node.classList.remove("is-arm");
  node.textContent = node.dataset.label || t("pvApprove");
}
function postDecision(domain, id, verb) {
  api(ROUTE.privacyDecision, { method: "POST", json: { domain: domain, id: id, verb: verb } }).then(function (reply) {
    if (reply && reply.privacy) { S.snap.privacy = reply.privacy; }
    if (reply && reply.ok) { toast("ok", String(reply.detail || t("decisionDone"))); }
    else { toast("err", String((reply && reply.detail) || t("decisionFailed"))); }
    renderStep4();
    return refreshSnapshot(true);
  }).catch(function (error) {
    fail("decisionFailed", error);
    refreshSnapshot(true);
  });
}
function pvAuthorize() {
  api(ROUTE.privacyAuthorize, { method: "POST", json: {} }).then(function (reply) {
    if (reply && reply.privacy) { S.snap.privacy = reply.privacy; }
    toast(reply && reply.ok ? "ok" : "warn", t("pvAuthAsked") + " · " + String((reply && reply.detail) || "—"));
    renderStep4();
    return refreshSnapshot(true);
  }).catch(function (error) {
    fail("pvAuthAskFailed", error);
    refreshSnapshot(true);
  });
}
function pvAddDir() {
  var cfg = pvConfig(), privacy = pvSnap();
  if (!cfg) { return; }
  cfg.workspaceDirectories = cfg.workspaceDirectories || [];
  if (cfg.workspaceDirectories.length >= Number(privacy.directoryCeiling || 0)) {
    toast("warn", t("pvDirMax") + " · " + String(privacy.directoryCeiling || 0));
    return;
  }
  cfg.workspaceDirectories.push("");
  markDirty();
  renderPvDirRows();
}
function pvRemoveDir(index) {
  var cfg = pvConfig();
  if (!cfg || !cfg.workspaceDirectories) { return; }
  cfg.workspaceDirectories.splice(Number(index), 1);
  markDirty();
  renderPvDirRows();
}
/* The readout is repainted from the last result rather than left as whatever string the
   previous click wrote: a language flip re-renders the panel, and a Chinese console that
   kept an English self-check line was measured in the browser on 2026-11-26. */
function pvCheckText() {
  var last = S.pvCheck;
  if (!last) { return ""; }
  if (last.kind === "off") { return t("pvCheckOff"); }
  if (last.kind === "none") { return t("pvCheckNone"); }
  if (last.kind === "failed") { return t("pvCheckFailed") + " · " + String(last.reason || "").slice(0, 200); }
  var slots = last.slots || [];
  if (!slots.length) { return t("pvCheckNone"); }
  return t("pvCheckFree") + " " + String(slots.length) + " · " + pvWhen(slots[0].start) +
    (slots[0].end ? " → " + pvWhen(slots[0].end) : "");
}
/* The self-check asks the node the question an assistant would ask, over the same route:
   a green line here means the bridge works, not merely that a switch is on. */
function pvCheck() {
  var out = el("pv-check-out"), button = el("pv-check");
  if (!out) { return; }
  var cfg = pvConfig();
  if (!cfg || !cfg.allowCalendarAccess) { S.pvCheck = { kind: "off" }; out.textContent = pvCheckText(); return; }
  if (button) { button.classList.add("is-disabled"); }
  out.textContent = t("loadingShort");
  var start = new Date(nodeNow());
  var end = new Date(start.getTime() + 7 * 86400000);
  api(ROUTE.toolAvailability, { method: "POST", json: { startIso: start.toISOString(), endIso: end.toISOString() } })
    .then(function (reply) {
      S.pvCheck = { kind: "free", slots: (reply && reply.freeSlots) || [] };
      out.textContent = pvCheckText();
    })
    .catch(function (error) {
      // A tool refusal is `{"ok":false,"refusal":"…"}` on a non-200, and `api()` only
      // unwraps an `error` key, so the refusal is pulled out here rather than shown raw.
      var raw = String(error && error.message ? error.message : error);
      var reason = raw;
      try {
        var parsed = JSON.parse(raw);
        if (parsed && parsed.refusal) { reason = String(parsed.refusal); }
      } catch (ignored) { /* a plain-text body is as good an answer */ }
      S.pvCheck = { kind: "failed", reason: reason };
      out.textContent = pvCheckText();
    })
    .then(function () {
      if (button) { button.classList.remove("is-disabled"); }
      return refreshSnapshot(true);
    });
}
function pvAuditCopy() {
  var rows = pvSnap().auditLog || [];
  if (!rows.length) { toast("warn", t("pvNoAudit")); return; }
  copyText(rows.map(function (row) {
    return [row.at, row.domain, row.action, row.outcome, row.detail]
      .filter(function (piece) { return piece !== null && piece !== undefined && String(piece).length; })
      .join(" · ");
  }).join("\n"));
}

/* ------------------------------------------------------------- rendering IO */
function renderStep1() {
  renderStats();
  renderGauge();
  renderToolchain();
  renderLadder();
  renderChecklist();
  renderDeployControls();
  if (S.logStep !== 1) { rebuildLog(); S.logStep = 1; }
}
function renderStep2() {
  renderPairing();
  renderDevices();
  renderBridge();
}
function renderStep3() {
  ensureForm(S.snap);
  renderEngines();
  renderSettingsViews();
  renderSaveBar();
}
function skeleton(id, rows, height) {
  var slot = el(id);
  if (!slot) { return; }
  clear(slot);
  var stack = h("div", { cls: "skel-stack" });
  for (var index = 0; index < rows; index += 1) {
    stack.appendChild(h("div", { cls: "skeleton", style: { height: (height || 16) + "px", width: (100 - index * 7) + "%" } }));
  }
  slot.appendChild(stack);
}
function renderPending() {
  skeleton("stats", 6, 60);
  skeleton("gauge", 1, 180);
  skeleton("toolchain", 1, 34);
  skeleton("ladder", 4, 22);
  skeleton("checklist", 3, 26);
  skeleton("pair-body", 3, 56);
  skeleton("devices", 2, 34);
  skeleton("bridge", 4, 60);
  skeleton("engines", 4, 74);
  skeleton("mesh", 4, 38);
  skeleton("sentinel", 3, 38);
  skeleton("ark", 3, 38);
  skeleton("drill", 1, 60);
  skeleton("pv-stats", 4, 56);
  skeleton("pv-proposals", 2, 86);
  skeleton("pv-bookings", 1, 66);
  skeleton("pv-audit", 3, 20);
  S.gauge = null;
  var body = el("log");
  if (body && !body.firstChild) { body.appendChild(h("div", { cls: "line" }, h("span", { cls: "line__m", text: t("loading") }))); }
  setText("install-badge", t("loadingShort"));
}
function renderAll() {
  if (!S.snap) { renderPending(); return; }
  renderTop();
  renderRail();
  if (S.step === 1) { renderStep1(); }
  else if (S.step === 2) { renderStep2(); }
  else if (S.step === 3) { renderStep3(); }
  else if (S.step === 4) { renderStep4(); }
  else { renderStep5(); }
  renderSaveBar();
}

/* ----------------------------------------------------------------- actions */
function copyText(text) {
  var value = String(text || "");
  if (!value) { toast("warn", t("copyFailed")); return; }
  function legacy() {
    var area = document.createElement("textarea");
    area.value = value;
    area.setAttribute("readonly", "readonly");
    area.style.position = "fixed";
    area.style.top = "-2000px";
    area.style.opacity = "0";
    document.body.appendChild(area);
    area.select();
    var ok = false;
    try { ok = document.execCommand("copy"); } catch (ignored) { ok = false; }
    document.body.removeChild(area);
    toast(ok ? "ok" : "err", t(ok ? "copyDone" : "copyFailed"));
  }
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(value).then(function () { toast("ok", t("copyDone")); }, legacy);
  } else {
    legacy();
  }
}
function resultLines(result) {
  var lines = [];
  lines.push((result.ok ? "✓ " : "✕ ") + String(result.headline || t("unknown")) +
    " · " + String(result.engine || "") + " · " + (result.deterministic ? "deterministic" : "model") +
    " · " + String(result.durationMs || 0) + " ms · " + stampOf(dateOf(result.at)));
  if (result.body) { lines.push(String(result.body)); }
  (result.artifacts || []).forEach(function (path) { lines.push("artifact  " + anon(String(path))); });
  var metrics = result.metrics || {};
  Object.keys(metrics).sort().forEach(function (key) {
    var value = metrics[key];
    lines.push("  " + key + " = " + (value && typeof value === "object" ? JSON.stringify(value) : String(value)));
  });
  return lines;
}
function appendResultLines(result) {
  var slot = el("cmdout");
  if (!slot) { return; }
  if (slot.firstChild && slot.textContent.charAt(0) === "—") { clear(slot); }
  resultLines(result).forEach(function (line) { slot.appendChild(h("div", { text: line })); });
  while (slot.children.length > 200) { slot.removeChild(slot.firstChild); }
  slot.scrollTop = slot.scrollHeight;
}

/* -------------------------------------------------------------- mutations */
function doInstallStart() {
  var button = el("btn-deploy");
  button.classList.add("is-disabled");
  api(ROUTE.installStart, { method: "POST" }).then(function () {
    button.classList.remove("is-disabled");
    toast("ok", t("deployStarted"));
    refreshSnapshot(true);
  }).catch(function (error) {
    button.classList.remove("is-disabled");
    fail("deployFailed", error);
  });
}
function doInstallCancel() {
  var button = el("btn-cancel");
  button.classList.add("is-disabled");
  api(ROUTE.installCancel, { method: "POST" }).then(function () {
    button.classList.remove("is-disabled");
    toast("ok", t("deployCancel"));
    refreshSnapshot(true);
  }).catch(function (error) {
    button.classList.remove("is-disabled");
    fail("deployCancelFailed", error);
  });
}
function doRotate() {
  api(ROUTE.pairingRotate, { method: "POST" }).then(function (offer) {
    PAIR_VIEW.name = "";
    PAIR_VIEW.code = "";
    S.qrNonce = (S.qrNonce || 0) + 1;
    var mask = offer && offer.pairingMask ? String(offer.pairingMask) : "…";
    toast("ok", t("rotate") + " · " + mask);
    return refreshSnapshot(true);
  }).catch(function (error) { fail("rotateFailed", error); });
}
function doRevoke(button) {
  var publicKey = button.getAttribute("data-key") || "";
  if (!publicKey) { return; }
  button.classList.add("is-disabled");
  api(ROUTE.pairingRevoke, { method: "POST", json: { publicKey: publicKey } }).then(function () {
    toast("ok", t("revokeDone"));
    return refreshSnapshot(true);
  }).catch(function (error) {
    button.classList.remove("is-disabled");
    fail("revokeFailed", error);
  });
}
function doToggle(button) {
  var kind = button.getAttribute("data-kind") || "";
  var next = button.getAttribute("aria-checked") !== "true";
  if (!kind) { return; }
  button.classList.add("is-pending");
  api(ROUTE.engineToggle, { method: "POST", json: { kind: kind, enabled: next } }).then(function (body) {
    button.classList.remove("is-pending");
    if (body && body.engines && body.hardware) { S.snap = body; S.clockOffset = new Date(body.serverTime).getTime() - Date.now(); }
    toast("ok", t(next ? "toggleOn" : "toggleOff") + " · " + kind);
    if (body && body.engines) { renderAll(); } else { refreshSnapshot(true); }
  }).catch(function (error) {
    button.classList.remove("is-pending");
    fail("toggleFailed", error);
    refreshSnapshot(true);
  });
}
function syncFormAfterSnapshot() {
  var settings = S.snap && S.snap.settings;
  if (!settings) { return; }
  if (!S.form || !S.dirty) {
    S.form = clone(settings);
    S.formBase = settings.revision;
    return;
  }
  /* Unsaved edits survive a background refresh, but the engine map and the
     revision baseline always track the node, because /api/engine/toggle writes
     the very same document and a stale copy could switch an engine back off. */
  S.form.enginesEnabled = clone(settings.enginesEnabled);
  S.formBase = settings.revision;
}
function doSave() {
  if (S.saving || !S.form) { return; }
  if (Number(S.formBase) !== nodeRevision()) {
    toast("warn", t("conflict"));
    S.form = null;
    S.formBuilt = false;
    S.dirty = false;
    refreshSnapshot(true);
    return;
  }
  var previousBase = Number(S.formBase);
  S.saving = true;
  renderSaveBar();
  api(ROUTE.settings, { method: "POST", json: S.form }).then(function (next) {
    S.saving = false;
    S.dirty = false;
    var applied = next && next.revision !== undefined ? Number(next.revision) : previousBase;
    if (applied > previousBase + 1) { toast("warn", t("conflict")); }
    S.form = clone(next || {});
    S.formBase = applied;
    S.formBuilt = false;
    return refreshSnapshot(true).then(function () {
      toast("ok", t("saveDone") + " · r" + String(applied));
    });
  }).catch(function (error) {
    S.saving = false;
    fail("saveFailed", error);
    refreshSnapshot(true);
  });
}
function doRevert() {
  if (!S.snap) { return; }
  S.form = clone(S.snap.settings || {});
  S.formBase = (S.snap.settings || {}).revision || 0;
  S.dirty = false;
  S.formBuilt = false;
  renderAll();
  toast("ok", t("reverted"));
}
function doDrill() {
  toast("ok", t("drillPending"));
  api(ROUTE.engineInvoke, { method: "POST", json: { kind: "phantom_sentinel", action: "drill", payload: {} } })
    .then(function (result) {
      S.drillResult = result || {};
      renderLockdowns();
      toast(result && result.ok ? "ok" : "err", t(result && result.ok ? "drillDone" : "drillFailed"));
      return refreshSnapshot(true);
    }).catch(function (error) { fail("drillFailed", error); });
}
function doReveal() {
  /* No path travels with the request: the node reveals the folder it seals
     into, so a page cannot point Finder at an arbitrary location. */
  api(ROUTE.engineInvoke, { method: "POST", json: { kind: "chrono_ark", action: "reveal", payload: {} } })
    .then(function (result) {
      appendResultLines(result || {});
      toast(result && result.ok ? "ok" : "warn", String((result && result.headline) || t("dirReveal")));
    }).catch(function (error) { fail("revealFailed", error); });
}
function doFetchRaw() {
  api(ROUTE.snapshot, { raw: true }).then(function (text) {
    var full = String(text || "");
    S.rawText = full;
    var slot = el("raw");
    var shown = full.length > 60000 ? full.slice(0, 60000) + " …" : full;
    slot.textContent = shown;
    if (shown !== full) { toast("warn", t("rawTruncated")); }
  }).catch(function (error) {
    el("raw").textContent = t("rawFailed") + " · " + (error && error.message ? String(error.message) : String(error));
    fail("rawFailed", error);
  });
}
function doCommand() {
  var box = el("cmd");
  var text = String(box.value || "").trim();
  if (!text) { toast("warn", t("cmdEmpty")); return; }
  api(ROUTE.command, { method: "POST", json: { text: text } }).then(function (result) {
    appendResultLines(result || {});
    toast(result && result.ok ? "ok" : "err", t(result && result.ok ? "cmdDone" : "cmdFailed"));
    return refreshSnapshot(true);
  }).catch(function (error) { fail("cmdFailed", error); });
}
function windowAdd() {
  var mesh = S.form.mesh;
  mesh.idleWindows = mesh.idleWindows || [];
  mesh.idleWindows.push({ startHour: 1, endHour: 7, weekdays: [2, 3, 4, 5, 6] });
  renderWindowList();
  markDirty();
}
function windowRemove(index) {
  var mesh = S.form.mesh;
  if (!mesh.idleWindows || index < 0 || index >= mesh.idleWindows.length) { return; }
  mesh.idleWindows.splice(index, 1);
  renderWindowList();
  markDirty();
}
function mountAdd() {
  var sentinel = S.form.sentinel;
  sentinel.unmountPaths = sentinel.unmountPaths || [];
  sentinel.unmountPaths.push("");
  renderMountList();
  markDirty();
}
function mountRemove(index) {
  var sentinel = S.form.sentinel;
  if (!sentinel.unmountPaths || index < 0 || index >= sentinel.unmountPaths.length) { return; }
  sentinel.unmountPaths.splice(index, 1);
  renderMountList();
  markDirty();
}

/* --------------------------------------------------------------- lifecycle */
function tick() {
  setText("clock", clockOf(new Date()));
  if (!S.snap) { return; }
  var node = S.snap.node || {};
  if (node.startedAt) {
    setText("foot-uptime", t("uptime") + " " + dur((nodeNow() - new Date(node.startedAt).getTime()) / 1000));
  }
  updatePairCountdown();
  updatePvCountdown();
  if (S.step === 1) { renderDeployControls(); }
  var alive = S.es && (S.es.readyState === 0 || S.es.readyState === 1);
  if (alive) { return; }
  if (!S.esTimer && Date.now() - CONN.lastOk > 8000) { openSSE(); }
  if (Date.now() - CONN.lastPoll > 20000) { refreshSnapshot(false); }
}
function boot() {
  if (S.booted) { return; }
  S.booted = true;
  el("log").addEventListener("scroll", onLogScroll);
  el("cmd").value = "::popopx_sys::NODE_CMD::shadow_cos::briefing::{}";
  el("raw").textContent = t("rawEmpty");
  el("cmdout").textContent = "—";
  applyLang();
  refreshSnapshot(true);
  openSSE();
  window.setInterval(tick, 1000);
  document.addEventListener("visibilitychange", function () {
    if (document.hidden) { return; }
    refreshSnapshot(true);
    if (!S.es) { openSSE(); }
  });
}

var PPX = {
  /* The picker is the node's setting, not a browser preference: the same value
     decides which catalog the page paints, which language the report templates
     are written in, and what the local model is asked to answer in. So the
     click is posted through the ordinary settings route, and a failed POST
     pulls the stored value back — the UI never claims a language the node is
     not using. */
  setLang: function (lang) {
    if (!localeKnown(lang) || lang === S.lang) { return; }
    S.lang = lang;
    S.formBuilt = false;
    S.engineKeys = "";
    applyLang();
    if (lang !== "en" && catalogFor(lang) === "en") { toast("warn", t("langFallback") + " · " + lang); }
    if (!S.snap || !S.snap.settings) { return; }
    if (S.dirty) { toast("warn", t("langSaveHint")); return; }
    var nextDocument = clone(S.snap.settings);
    nextDocument.language = lang;
    S.langPending = true;
    api(ROUTE.settings, { method: "POST", json: nextDocument }).then(function (applied) {
      S.langPending = false;
      adoptLanguage(applied && applied.language ? applied.language : lang);
      return refreshSnapshot(true);
    }).catch(function (error) {
      S.langPending = false;
      fail("langSaveFailed", error);
      refreshSnapshot(true);
    });
  },
  step: function (number) {
    S.step = number;
    S.logStep = 0;
    [1, 2, 3, 4, 5].forEach(function (index) {
      show("step-" + index, index === number);
      var button = el("rail-" + index);
      if (button) { button.classList.toggle("is-on", index === number); }
    });
    renderAll();
    if (number === 5) { hvPoll(); }
  },
  retry: function () {
    if (S.esTimer) { window.clearTimeout(S.esTimer); S.esTimer = null; }
    S.esBackoff = 1000;
    openSSE();
    refreshSnapshot(true);
  },
  installStart: doInstallStart,
  installCancel: doInstallCancel,
  /* Pinning a model is a settings write, not a new route: the same document the
     save bar posts carries `llmModelOverride`, and the node answers with the
     snapshot it just applied, so the picker settles on what the engines will
     actually run rather than on what was clicked. */
  modelPick: function () {
    var select = el("model-select");
    if (!select || !S.snap || !S.snap.settings) { return; }
    if (S.dirty) { toast("warn", t("langSaveHint")); return; }
    var model = modelById(select.value);
    var next = clone(S.snap.settings);
    next.llmModelOverride = model ? String(model.ref) : "";
    api(ROUTE.settings, { method: "POST", json: next }).then(function () {
      toast("ok", next.llmModelOverride ? t("modelSwitched") + " · " + next.llmModelOverride : t("modelUnpinned"));
      return refreshSnapshot(true);
    }).catch(function (error) {
      fail("modelSwitchFailed", error);
      refreshSnapshot(true);
    });
  },
  modelCopy: function () { copyText(S.modelPull); },
  logFilter: function () {
    S.logFilter = el("log-filter").value;
    rebuildLog();
  },
  logClear: function () {
    clear(el("log"));
    el("log").appendChild(emptyState("logEmpty"));
    toast("ok", t("logCleared"));
  },
  logCopy: function () {
    var lines = S.entries.filter(logPasses).map(function (entry) {
      return clockOf(dateOf(entry.time)) + " " + (LEVEL_GLYPH[entry.level] || "›") +
        " [" + entry.channel + "]" + (entry.phase ? ":" + entry.phase : "") + " " + entry.text;
    });
    if (!lines.length) { toast("warn", t("logEmpty")); return; }
    copyText(lines.join("\n"));
  },
  logUnlock: function () {
    S.autoScroll = true;
    show("lockbtn", false);
    var body = el("log");
    if (body) { body.scrollTop = body.scrollHeight; }
  },
  rotatePairing: doRotate,
  revokeDevice: doRevoke,
  qrRetry: function () {
    PAIR_VIEW.name = "";
    S.qrNonce = (S.qrNonce || 0) + 1;
    if (S.snap) { renderPairing(); }
  },
  copyThis: function (name) { copyText(S.copyable[name]); },
  toggleEngine: doToggle,
  save: doSave,
  revert: doRevert,
  drill: doDrill,
  revealDir: doReveal,
  pvAuthorize: pvAuthorize,
  pvCheck: pvCheck,
  pvDecide: pvDecide,
  pvAddDir: pvAddDir,
  pvRemoveDir: pvRemoveDir,
  pvAuditCopy: pvAuditCopy,
  hvScan: hvScan,
  hvStatus: hvStatus,
  hvStoreHome: hvStoreHome,
  hvStoreCalDav: hvStoreCalDav,
  hvAddEntity: hvAddEntity,
  hvRemoveEntity: hvRemoveEntity,
  hvAddTarget: hvAddTarget,
  hvRemoveTarget: hvRemoveTarget,
  upCheck: upCheck,
  upDecide: upDecide,
  dcRefresh: dcRefresh,
  dcAddFolder: dcAddFolder,
  dcRemoveFolder: dcRemoveFolder,
  dcAddFeed: dcAddFeed,
  dcRemoveFeed: dcRemoveFeed,
  dcAddMcp: dcAddMcp,
  dcRemoveMcp: dcRemoveMcp,
  geStart: geStart,
  geStop: geStop,
  geHealth: geHealth,
  geControl: geInvoke,
  asRun: asRun,
  asDecide: asDecide,
  asAddRepair: asAddRepair,
  asRemoveRepair: asRemoveRepair,
  windowAdd: windowAdd,
  windowRemove: windowRemove,
  mountAdd: mountAdd,
  mountRemove: mountRemove,
  devToggle: function () {
    var drawer = el("drawer");
    S.devOpen = !S.devOpen;
    drawer.classList.toggle("is-open", S.devOpen);
    show("dev-body", S.devOpen);
    var title = drawer.querySelector("h3");
    if (title) { title.textContent = t("devTitle"); }
    if (S.devOpen && !S.rawText) { doFetchRaw(); }
  },
  fetchRaw: doFetchRaw,
  rawCopy: function () {
    if (!S.rawText) { doFetchRaw(); return; }
    copyText(S.rawText);
  },
  cmdSend: doCommand,
  cmdClear: function () { clear(el("cmdout")); el("cmdout").textContent = "—"; },
  dismiss: function (button) {
    var node = button.parentNode;
    if (node && node.parentNode) { node.parentNode.removeChild(node); }
  }
};

window.PPX = PPX;
boot();
</script>
</body>
</html>

"""#
}

// MARK: - Loopback console server

/// The whole local web console: an HTTP/1.1 + SSE listener on `Network.framework`
/// plus the single-page wizard it serves.
///
/// Concurrency shape, because it is the part that is easy to get wrong:
///
/// * One serial `DispatchQueue` receives every `NWConnection` callback. Nothing
///   in this file blocks it — no semaphore, no `Thread.sleep`, no `waitUntilExit`.
/// * Every piece of mutable state lives in an actor: this server (listener,
///   token, registries), `WEBConnection` (one socket's read pump), `WEBWriter`
///   (one socket's write queue) and `WEBSSEChannel` (one event subscription).
/// * Only `Sendable` values cross those boundaries. `NWConnection`, `NWListener`,
///   `NWEndpoint`, `NWPath` and both `State` enums are `Sendable` in the macOS 14
///   SDK, so no `@unchecked` box is needed anywhere in this file.
public actor LocalWebConsoleServer {

    // MARK: Wire limits

    /// Anything bigger gets `413` at the head, before a single body byte is
    /// buffered. The largest legitimate document here is a settings POST.
    public static let maxBodyBytes = 8 * 1_024 * 1_024
    static let maxHeadBytes = 64 * 1_024
    static let maxTargetBytes = 8 * 1_024
    static let maxHeaderCount = 100
    static let maxConnections = 64

    /// Every socket shares this one queue. One queue means no lock, and it keeps
    /// reads and writes on the same socket strictly ordered.
    static let workQueue = DispatchQueue(label: "chat.popopx.macnode.console", qos: .utility)

    // MARK: Response headers

    /// `default-src 'self'` with an explicit `'unsafe-inline'` for `style-src`
    /// and `script-src`.
    ///
    /// Why inline is the right trade here rather than a hole: the document is
    /// one static byte string (`WEBConsoleHTML.document`) that never receives a
    /// Swift, user or remote value at template time — every dynamic node on the
    /// page is built with `createElement`/`textContent`, and the only place
    /// markup is assigned from a string anywhere in the page is one hard-coded
    /// SVG path table inside `svgIcon`, which takes no arguments. The inline
    /// blocks are therefore the app's own audited code, delivered from the same
    /// origin over loopback; an attacker able to change them already has the
    /// binary. The stricter alternative — two extra asset routes plus a
    /// per-response nonce — buys nothing against a 127.0.0.1-only origin while
    /// breaking the "one embedded document, no asset routes" requirement, so the
    /// constraint is enforced in the renderer instead of in the header.
    static let securityPolicy = [
        "default-src 'self'",
        "script-src 'self' 'unsafe-inline'",
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data:",
        "connect-src 'self'",
        "font-src 'self'",
        "object-src 'none'",
        "base-uri 'none'",
        "form-action 'none'",
        "frame-ancestors 'none'"
    ].joined(separator: "; ")

    /// Stamped on every response and every event stream. `response(...)` is the
    /// only way to build a body, so a route cannot forget one.
    static let securityHeaders: [(String, String)] = [
        ("X-Content-Type-Options", "nosniff"),
        ("X-Frame-Options", "DENY"),
        ("Referrer-Policy", "no-referrer"),
        ("Cross-Origin-Resource-Policy", "same-origin"),
        ("Content-Security-Policy", securityPolicy)
    ]

    // MARK: State

    /// Everything the console may touch. Deliberately existential: the console
    /// cannot reach into an engine, only ask the node.
    private let facade: any NodeConsoleFacade
    private let host: String
    private let requestedPort: UInt16

    /// Random per launch, never persisted. A token that survives a reboot is a
    /// token that can leak out of an old bookmark.
    public let token: String

    private var listener: NWListener?
    private var boundPort: UInt16?
    private var listening = false
    private var stopped = false
    private var connections: [UUID: WEBConnection] = [:]
    private var channels: [UUID: WEBSSEChannel] = [:]
    private var readyWaiter: CheckedContinuation<UInt16, any Error>?
    private var listenerFailure: String?
    private let bootDate = Date()

    /// Everything this server hands to a browser is a displayed surface, so
    /// `PairingOffer` gains its opaque link here and nowhere in the node's own store.
    private let encoder = NodeJSON.encoder(displayingOpaqueLinks: true)
    private let decoder = NodeJSON.decoder()

    // MARK: Life and death

    public init(facade: any NodeConsoleFacade,
                host: String = NodeWire.consoleHost,
                port: UInt16 = NodeWire.consolePort) {
        self.facade = facade
        self.host = host
        self.requestedPort = port
        self.token = TextKit.randomToken()
    }

    /// Binds the loopback socket and waits until the port is actually ours. Does
    /// not touch the browser: call `openInBrowser()` when the UI is ready.
    public func start() async throws {
        guard !listening else { return }
        guard requestedPort > 0 else { throw WEBConsoleError.portOutOfRange }
        guard Self.isLoopbackLiteral(host) else {
            throw WEBConsoleError.addressNotLoopback(host)
        }
        stopped = false
        listenerFailure = nil

        let parameters = NWParameters.tcp
        // Loopback is not a preference, it is the security model: nothing on this
        // server is authenticated by anything but the bearer token, and the
        // console can start installers, rotate pairing offers and toggle engines.
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        parameters.acceptLocalOnly = true
        guard let port = NWEndpoint.Port(rawValue: requestedPort) else {
            throw WEBConsoleError.portOutOfRange
        }
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)

        // The port rides in `requiredLocalEndpoint` alone. Handing the same port to
        // `NWListener(using:on:)` as well is rejected with POSIX `EINVAL` (22), and
        // the pinned endpoint is the one half of the loopback guarantee this type
        // actually enforces, so the argument goes rather than the pin.
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.noteListener(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            Task { await self.accept(connection) }
        }
        self.listener = listener
        listener.start(queue: Self.workQueue)

        do {
            boundPort = try await waitUntilReady()
        } catch {
            listener.cancel()
            self.listener = nil
            throw WEBConsoleError.listenerFailed(listenerFailure ?? error.localizedDescription)
        }
        listening = true
        audit()
    }

    /// Closes the listener, every socket and every event subscription. Safe to
    /// call twice, and safe to call when it never started.
    public func stop() async {
        stopped = true
        listening = false
        let live = Array(channels.values)
        channels.removeAll(keepingCapacity: false)
        for channel in live { await channel.close() }
        let open = Array(connections.values)
        connections.removeAll(keepingCapacity: false)
        for connection in open { await connection.shutdown() }
        listener?.cancel()
        listener = nil
        boundPort = nil
        readyWaiter?.resume(throwing: WEBConsoleError.notListening)
        readyWaiter = nil
    }

    /// Hands the tokenised URL to the default browser. Kept out of `start()` so
    /// the console can be started head-first in tests and CI.
    public func openInBrowser() async {
        let target = url
        #if canImport(AppKit)
        await MainActor.run {
            // `open` answers with a Bool that means "the browser accepted the
            // request", not "the page loaded"; the page itself reports liveness.
            _ = NSWorkspace.shared.open(target)
        }
        #else
        _ = target
        #endif
    }

    /// The console URL, token included.
    ///
    /// The token rides in the query because a top-level navigation cannot attach
    /// an `X-PPX-Token` header, and `GET /` has to answer with something. That is
    /// acceptable only under three properties this type guarantees: the socket is
    /// loopback-bound by construction (`requiredInterfaceType = .loopback`,
    /// `acceptLocalOnly`, an explicit `127.0.0.1` required local endpoint and the
    /// `audit()` check below); the URL is never published anywhere except to the
    /// owner's own browser by the app itself, and dies with the process; and the
    /// page loads no third-party resource at all while sending
    /// `Referrer-Policy: no-referrer`, so the token cannot travel onward even if
    /// the owner pastes the URL somewhere. It is also the only place the browser
    /// will put it for us: the QR is an `<img>`, and an `<img>` cannot set
    /// headers.
    public var url: URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = Int(boundPort ?? requestedPort)
        components.path = ConsoleRoute.index
        components.queryItems = [URLQueryItem(name: NodeWire.consoleTokenQuery, value: token)]
        return components.url ?? URL(string: "http://\(host):\(requestedPort)/")!
    }

    /// `true` once `start()` has returned without throwing.
    public var isListening: Bool { listening }

    /// The port actually bound; equal to the requested port in the normal case.
    public var boundConsolePort: UInt16 { boundPort ?? requestedPort }

    /// Live event-stream viewers.
    public var streamCount: Int { channels.count }

    // MARK: - Startup audit

    private func waitUntilReady() async throws -> UInt16 {
        if let failure = listenerFailure { throw WEBConsoleError.listenerFailed(failure) }
        return try await withCheckedThrowingContinuation { continuation in
            if let port = listener?.port?.rawValue, listener?.state == .ready {
                continuation.resume(returning: port)
                return
            }
            readyWaiter = continuation
        }
    }

    private func noteListener(_ state: NWListener.State) {
        switch state {
        case .ready:
            let port = listener?.port?.rawValue ?? requestedPort
            boundPort = port
            if let waiter = readyWaiter {
                readyWaiter = nil
                waiter.resume(returning: port)
            }
        case .waiting(let error):
            listenerFailure = error.localizedDescription
        case .failed(let error):
            listening = false
            listenerFailure = error.localizedDescription
            if let waiter = readyWaiter {
                readyWaiter = nil
                waiter.resume(throwing: error)
            }
        case .cancelled:
            listening = false
        case .setup:
            break
        @unknown default:
            break
        }
    }

    /// One operator-visible line at startup. No path, no token, ever.
    private func audit() {
        let endpoint = listener?.parameters.requiredLocalEndpoint
        let pinned = endpoint.map { Self.isLoopback($0) } ?? true
        assert(endpoint == nil || pinned, "POPOPX console must only ever bind loopback")
        print("POPOPX console · http://\(host):\(boundConsolePort)/ · loopback=\(pinned ? "yes" : "NO — MISCONFIGURED") · body cap \(Self.maxBodyBytes / 1_048_576) MiB · bearer token lives until the app quits")
        if !pinned {
            print("POPOPX console · AUDIT: resolved endpoint \(String(describing: endpoint)) is not loopback; refusing to serve")
            Task { await self.stop() }
        }
    }

    // MARK: - Accept

    private func accept(_ connection: NWConnection) async {
        guard listening, !stopped else {
            connection.cancel()
            return
        }
        let viaLoopback = connection.currentPath.map { Self.pathIsLoopback($0) } ?? true
        guard Self.isLoopback(connection.endpoint), viaLoopback else {
            // Defence in depth: `requiredInterfaceType = .loopback` should make
            // this unreachable, but a refused socket is cheaper than an argument.
            print("POPOPX console · AUDIT: refused a peer that did not arrive on lo0")
            connection.cancel()
            return
        }
        // The cap is counted here, not by `NWListener.newConnectionLimit`: that
        // property stops handing out sockets once it has seen `maxConnections`
        // connections over the life of the listener rather than at one time, so a
        // console configured for 64 went permanently deaf at its 64th socket — the
        // browser's own reloads included. `connections` holds the handlers that are
        // live right now, and `connectionEnded` is what empties it.
        guard connections.count < Self.maxConnections else {
            connection.cancel()
            return
        }
        let handler = WEBConnection(connection: connection, server: self)
        connections[handler.identifier] = handler
        await handler.begin()
    }

    func connectionEnded(_ identifier: UUID) {
        connections[identifier] = nil
    }

    func streamEnded(_ identifier: UUID) {
        channels[identifier] = nil
    }

    /// A channel that gave up on a slow reader. The viewer reconnects on its own;
    /// the node never stalls waiting for a browser that stopped reading.
    func streamDropped(_ identifier: UUID, reason: String) {
        channels[identifier] = nil
        print("POPOPX console · dropped one event stream (\(reason)); viewers left: \(channels.count)")
    }

    // MARK: - Loopback tests

    /// Literal form only. `0.0.0.0`, a LAN address and a hostname are all
    /// rejected before a socket exists, so a mistyped host cannot silently
    /// expose the console to a network.
    static func isLoopbackLiteral(_ host: String) -> Bool {
        let text = host.trimmingCharacters(in: .whitespaces).lowercased()
        if text == "localhost" || text == "::1" { return true }
        let parts = text.split(separator: ".")
        guard parts.count == 4, parts.first == "127" else { return false }
        return parts.allSatisfy { part in
            part.count <= 3 && (Int(part).map { (0...255).contains($0) } ?? false)
        }
    }

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else {
            // A unix or opaque endpoint peer is local by construction, but this
            // server never binds one, so refuse rather than assume.
            return false
        }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback
        case .name(let name, _): return name == "localhost"
        @unknown default: return false
        }
    }

    /// `true` when the socket travelled on `lo0`. Absent path information is
    /// treated as loopback because the listener itself is pinned to `lo0`.
    static func pathIsLoopback(_ path: NWPath) -> Bool {
        guard let first = path.availableInterfaces.first else { return true }
        return first.type == .loopback
    }

    // MARK: - Routing

    /// One parsed request in, one dispatch outcome out. `.stream` means the
    /// socket became an event stream and must not receive another response.
    func serve(_ request: WEBHTTPRequest,
               on connection: WEBConnection,
               writer: WEBWriter) async -> WEBDispatch {
        guard listening, !stopped else {
            return .response(failure(.notListening, path: request.path, keepAlive: false))
        }
        let path = Self.normalisedPath(from: request.path)
        let keepAlive = request.keepAliveWanted
        do {
            guard let response = try await route(request, path: path, connection: connection, writer: writer) else {
                return .stream
            }
            let final = request.method == "HEAD" ? Self.withoutBody(response) : response
            return .response(Self.stampingConnection(final, keepAlive: keepAlive))
        } catch let error as WEBConsoleError {
            return .response(Self.stampingConnection(failure(error, path: path, keepAlive: keepAlive),
                                                     keepAlive: keepAlive && error.httpStatus < 500))
        } catch is CancellationError {
            return .nothing
        } catch {
            return .response(Self.stampingConnection(failure(.sendFailed(error.localizedDescription),
                                                             path: path,
                                                             keepAlive: false),
                                                     keepAlive: false))
        }
    }

    /// The route table. Paths are matched against `ConsoleRoute` literals and
    /// never against a percent-decoded form, so `/api/%65vents` is a 404 rather
    /// than a smuggled hit, and no route resolves to a file on disk.
    private func route(_ request: WEBHTTPRequest,
                       path: String,
                       connection: WEBConnection,
                       writer: WEBWriter) async throws -> WEBHTTPResponse? {
        if path == ConsoleRoute.index {
            guard Self.allows(request.method, for: path) else {
                throw WEBConsoleError.unsupportedMethod(request.method)
            }
            let presented = (request.header(NodeWire.consoleTokenHeader) ?? "")
                + (request.queryValue(NodeWire.consoleTokenQuery) ?? "")
            if presented.isEmpty {
                // A bare navigation is pointed at the tokenised form instead of
                // getting a 401 wall. Safe by construction, not by taste: this
                // address only exists on 127.0.0.1, only the app itself ever
                // hands it out (to the owner's own browser), the token dies with
                // the process, `no-referrer` stops it travelling onward and the
                // page fetches nothing remote. See `url`.
                let banner = Data("redirecting to the tokenised console".utf8)
                return WEBHTTPResponse(status: 302,
                                       reason: "Found",
                                       typeHeader: "text/plain; charset=utf-8",
                                       headers: Self.securityHeaders
                                           + [("Cache-Control", "no-store")]
                                           + [("Content-Length", String(banner.count))]
                                           + [("Location", "\(ConsoleRoute.index)?\(NodeWire.consoleTokenQuery)=\(token)")],
                                       body: banner)
            }
            guard authorized(request) else {
                throw WEBConsoleError.unauthorized
            }
            return response(Data(WEBConsoleHTML.document.utf8),
                            type: "text/html; charset=utf-8",
                            status: 200)
        }

        guard path.hasPrefix("/api/") || path.hasPrefix(ConsoleRoute.toolPrefix)
            || path.hasPrefix(ConsoleRoute.discoveryPrefix) else {
            throw WEBConsoleError.notFound(path)
        }
        // Every API route, without exception, needs the bearer. This is the only
        // gate: no cookie, no session, no "localhost is special".
        guard authorized(request) else {
            throw WEBConsoleError.unauthorized
        }
        guard Self.allows(request.method, for: path) else {
            throw WEBConsoleError.unsupportedMethod(request.method)
        }

        // Tool paths are prefixed rather than literal — `/v1/tools/{domain}/{action}`,
        // with a proposal id appended for the three decision actions — so they are
        // shaped by `PrivacyToolRoute`, the same parser the phone entry point uses.
        // Anything it refuses has never reached the engine.
        if path.hasPrefix(ConsoleRoute.toolPrefix) {
            return try await routeTool(request: request, path: path)
        }

        switch path {
        case ConsoleRoute.snapshot:
            return try json(await facade.snapshot())

        case ConsoleRoute.health:
            let snapshot = await facade.snapshot()
            let health = WEBHealth(
                ok: listening && !stopped,
                service: AppPaths.appName,
                version: NodeVersion.current.semanticString,
                node: snapshot.node.displayName,
                consolePort: boundConsolePort,
                loopback: listener?.parameters.requiredLocalEndpoint.map { Self.isLoopback($0) } ?? false,
                viewers: channels.count,
                uptimeSeconds: max(0, Int(Date().timeIntervalSince(bootDate))),
                serverTime: Date()
            )
            return try json(health)

        case ConsoleRoute.events:
            // Long-lived. The read side of this socket stops being pumped, so a
            // viewer waiting for events costs one task and no pool thread.
            try await openEvents(connection: connection, writer: writer)
            return nil

        case ConsoleRoute.installStart:
            await facade.startInstall()
            return try json(WEBStatus(ok: true, detail: "install requested"))

        case ConsoleRoute.installCancel:
            await facade.cancelInstall()
            return try json(WEBStatus(ok: true, detail: "cancel requested"))

        case ConsoleRoute.pairingRotate:
            guard let offer = await facade.rotatePairing() else {
                throw WEBConsoleError.noPairingOffer
            }
            return try json(offer)

        case ConsoleRoute.pairingQR:
            let size = Self.clampedPixelSize(request.queryValue("size"))
            guard let asset = await facade.pairingQR(pixelSize: size) else {
                throw WEBConsoleError.noPairingOffer
            }
            return response(asset.png, type: "image/png", status: 200, length: asset.png.count)

        case ConsoleRoute.pairingRevoke:
            let body: WEBRevokeRequest = try decode(WEBRevokeRequest.self, from: request)
            let key = body.publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw WEBConsoleError.badEngine("publicKey is required") }
            await facade.revokePairing(publicKey: key)
            return try json(WEBStatus(ok: true, detail: AppPaths.anonymise(key)))

        case ConsoleRoute.settings:
            let submitted: NodeSettings = try decode(NodeSettings.self, from: request)
            return try json(await facade.updateSettings(submitted))

        case ConsoleRoute.engineToggle:
            let body: WEBEngineToggleRequest = try decode(WEBEngineToggleRequest.self, from: request)
            guard let kind = EngineKind(rawValue: body.kind) else {
                throw WEBConsoleError.unknownEngine(body.kind)
            }
            await facade.setEngineEnabled(kind, enabled: body.enabled)
            // The fresh snapshot rides back on the same round trip, which is what
            // lets the switch settle without a second request.
            return try json(await facade.snapshot())

        case ConsoleRoute.engineInvoke:
            let body: WEBEngineInvokeRequest = try decode(WEBEngineInvokeRequest.self, from: request)
            guard let kind = EngineKind(rawValue: body.kind) else {
                throw WEBConsoleError.unknownEngine(body.kind)
            }
            let action = body.action.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !action.isEmpty else { throw WEBConsoleError.badEngine("action is required") }
            return try json(await facade.invokeEngine(kind, action: action, payload: body.payload ?? [:]))

        case ConsoleRoute.privacyAuthorize:
            // The one console-only privacy route: it raises the TCC dialog, which no
            // tool path may do. The reply is the state macOS settled on, plus the
            // fresh snapshot so the panel can settle without a second round trip.
            let state = await facade.requestCalendarAccess()
            let snapshot = await facade.snapshot()
            return try json(WEBPrivacyAuthorizeResponse(
                ok: state == PrivacyAuthorization.authorized || state == PrivacyAuthorization.fullAccess,
                detail: state,
                privacy: snapshot.privacy
            ))

        case ConsoleRoute.privacyDecision:
            // The console's approval click. `domain` and `verb` are checked here rather
            // than passed down: the route is the only place the console's intent is
            // turned into a ledger call, so it is where a malformed click must die.
            //
            // `domain` is read through the same resolver the tool path uses, because a hub
            // card carries the ledger's audit domain (`smartHome`) rather than the typed
            // namespace (`home`) — refusing it here would leave a proposal the phone can
            // approve and the console cannot.
            let body: WEBPrivacyDecisionRequest = try decode(WEBPrivacyDecisionRequest.self, from: request)
            let domain = body.domain.trimmingCharacters(in: .whitespacesAndNewlines)
            let verb = body.verb.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = body.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard PrivacyToolRoute.namespace(accepting: domain) != nil,
                  verb == PrivacyToolAction.approve || verb == PrivacyToolAction.reject,
                  PrivacyToolRoute.isSafeId(id) else {
                throw WEBConsoleError.badEngine("domain、id 与 verb 需合法 / domain, id and verb must each be valid")
            }
            let outcome = await facade.privacyDecision(domain: domain, id: id, verb: verb)
            let snapshot = await facade.snapshot()
            let detail = outcome.fields["message"]?.stringValue
                ?? outcome.fields["refusal"]?.stringValue
                ?? (outcome.ok ? "已执行 / applied" : "已拒绝 / refused")
            return try json(WEBPrivacyDecisionResponse(
                ok: outcome.ok,
                detail: detail,
                status: outcome.status,
                privacy: snapshot.privacy
            ))

        case ConsoleRoute.updateCheck:
            // Detection only. The facade fetches and verifies the signed manifest; no
            // package is fetched here and the installer is not reachable from this path.
            return try json(await facade.updateCheck())

        case ConsoleRoute.updateDecision:
            // The owner's click, and the only console road to a download. The receipt
            // is minted inside the facade, so the page sends a verb and nothing else.
            let body: WEBUpdateDecisionRequest = try decode(WEBUpdateDecisionRequest.self, from: request)
            let verb = body.verb.trimmingCharacters(in: .whitespacesAndNewlines)
            guard verb == "approve" || verb == "snooze" else {
                throw WEBConsoleError.badEngine("verb 必须为 approve 或 snooze / verb must be approve or snooze")
            }
            return try json(await facade.updateDecision(verb: verb))

        case ConsoleRoute.discoverRefresh:
            // The 「立即刷新」 button. The aggregator itself enforces the switch and a
            // 60-second gap, so a double click cannot become two LAN scans.
            return try json(await facade.discoverRefresh())

        case ConsoleRoute.discoveryCapabilities:
            // Read-only and never waiting: the snapshot call answers from the last
            // measurement and starts a background pass when it is stale.
            return try json(await facade.discoverySnapshot(force: false))

        case ConsoleRoute.discoveryScan:
            // The 「立即探测」 button: this is the one path that waits for the measurement,
            // because the owner clicked precisely because they wanted the answer now.
            return try json(await facade.discoverySnapshot(force: true))

        case ConsoleRoute.hubCredential:
            // Console-only, like the two privacy routes above it. The value is handed
            // straight to the store and is never echoed: the reply is the reference, and an
            // error carries the reason rather than the body that caused it.
            let body: WEBHubCredentialRequest = try decode(WEBHubCredentialRequest.self, from: request)
            let bridge = body.bridge.trimmingCharacters(in: .whitespacesAndNewlines)
            let server = body.serverId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bridge.isEmpty, server.count <= 64, !body.secret.isEmpty else {
                throw WEBConsoleError.badEngine("桥接类别与凭据均需填写 / bridge and credential must both be present")
            }
            let outcome = await facade.storeHubCredential(bridge: bridge, serverID: server, secret: body.secret)
            return try json(WEBHubCredentialResponse(
                ok: outcome.ok,
                detail: outcome.fields["detail"]?.stringValue
                    ?? outcome.fields["refusal"]?.stringValue
                    ?? (outcome.ok ? "已存入 / stored" : "未存入 / not stored"),
                reference: outcome.fields["reference"]?.stringValue,
                status: outcome.status
            ))

        case ConsoleRoute.commandInject:
            let body: WEBCommandRequest = try decode(WEBCommandRequest.self, from: request)
            let text = body.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw WEBConsoleError.emptyBody }
            // A human typing into the developer drawer usually leaves the prefix
            // off; wrapping keeps the wire grammar single-sourced in `NodeWire`.
            let line = text.hasPrefix(NodeWire.commandPrefix) ? text : NodeWire.commandPrefix + text
            return try json(await facade.submitWireCommand(line))

        case ConsoleRoute.godsEyeControl:
            // Console-only. The verb allow-list lives in the bridge, so the route and
            // the page cannot disagree about what a click may ask for.
            let body: WEBGodsEyeControlRequest = try decode(WEBGodsEyeControlRequest.self, from: request)
            let verb = body.verb.trimmingCharacters(in: .whitespacesAndNewlines)
            guard GodsEyeViewBridge.supportedVerbs.contains(verb) else {
                throw WEBConsoleError.badEngine("未知控制指令 / unknown control verb: \(verb)")
            }
            return try json(await facade.godsEyeControl(verb: verb))

        case ConsoleRoute.godsEyeCredential:
            // Console-only, like `/api/hub/credential`: the value is handed straight to
            // the store and never echoed. The reply is the reference.
            let body: WEBGodsEyeCredentialRequest = try decode(WEBGodsEyeCredentialRequest.self, from: request)
            let source = body.source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard GodsEyeDataSource(rawValue: source) != nil, !body.secret.isEmpty else {
                throw WEBConsoleError.badEngine("数据源与凭据均需填写 / source and credential must both be present")
            }
            let outcome = await facade.storeGodsEyeCredential(sourceID: source, secret: body.secret)
            return try json(WEBGodsEyeCredentialResponse(
                ok: outcome.ok,
                detail: outcome.fields["detail"]?.stringValue
                    ?? outcome.fields["refusal"]?.stringValue
                    ?? (outcome.ok ? "已存入 / stored" : "未存入 / not stored"),
                reference: outcome.fields["reference"]?.stringValue,
                status: outcome.status
            ))

        case ConsoleRoute.assistantControl:
            // Console-only: a one-shot briefing/patrol/mail run or a queue cancel.
            // The verb list is fixed here so the page cannot invent an action.
            let body: WEBAssistantControlRequest = try decode(WEBAssistantControlRequest.self, from: request)
            let verb = body.verb.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ["briefingNow", "patrolNow", "refreshMail", "proposeDrafts", "cancelPending"].contains(verb) else {
                throw WEBConsoleError.badEngine("未知私人助手指令 / unknown assistant verb: \(verb)")
            }
            return try json(await facade.assistantControl(verb: verb))

        case ConsoleRoute.assistantDecision:
            // The console's approval click. Only an id and a verb travel: the receipt
            // is minted inside the node, so a leaked poll response is not a capability.
            let body: WEBAssistantDecisionRequest = try decode(WEBAssistantDecisionRequest.self, from: request)
            let id = body.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let verb = body.verb.trimmingCharacters(in: .whitespacesAndNewlines)
            guard PrivacyToolRoute.isSafeId(id), verb == "approve" || verb == "reject" else {
                throw WEBConsoleError.badEngine("id 与 verb 需合法 / id and verb must both be valid")
            }
            return try json(await facade.assistantDecision(id: id, verb: verb))

        case ConsoleRoute.assistantMailCredential:
            // Console-only, like the hub credential route: the value goes straight to
            // the assistant's Keychain store and the reply carries only the reference.
            let body: WEBAssistantMailCredentialRequest = try decode(WEBAssistantMailCredentialRequest.self, from: request)
            let kind = body.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard kind == "imap" || kind == "smtp", !body.secret.isEmpty,
                  body.secret.utf8.count <= HubSecrets.maximumSecretLength else {
                throw WEBConsoleError.badEngine("凭据类别需为 imap 或 smtp / kind must be imap or smtp")
            }
            return try json(await facade.storeMailCredential(kind: kind, secret: body.secret))

        default:
            throw WEBConsoleError.notFound(path)
        }
    }

    /// One tool call: path shapes it, body argues it, the engine answers it.
    ///
    /// The body is read as a JSON object rather than into a DTO because the tool
    /// arguments are the assistant-facing contract (`startIso`, `durationMinutes`,
    /// `bookingRefId`…), and a missing key means "use the owner's saved preference"
    /// — a distinction a struct with defaults cannot express after decoding.
    private func routeTool(request: WEBHTTPRequest, path: String) async throws -> WEBHTTPResponse {
        guard var call = PrivacyToolRoute.parse(path: path, source: "bot-studio") else {
            throw WEBConsoleError.notFound(path)
        }
        if !request.body.isEmpty {
            guard let text = String(data: request.body, encoding: .utf8) else {
                throw WEBConsoleError.undecodableBody(typeName: "UTF-8 JSON object")
            }
            guard var fields = JSONValue.parse(text).objectValue else {
                throw WEBConsoleError.undecodableBody(typeName: "JSON object")
            }
            // A body may not re-point a decision at some other proposal: the id in
            // the path is the one the caller was handed, and this route is the only
            // place they can be told which one they are approving.
            if !call.id.isEmpty { fields["proposalId"] = .string(call.id) }
            call.payload = fields
        }
        let outcome = await facade.privacyTool(call)
        return response(Data(outcome.body.utf8), type: "application/json; charset=utf-8", status: outcome.status)
    }

    /// Read routes answer `GET`/`HEAD`, mutation routes answer `POST`, nothing
    /// answers `OPTIONS`: the page is same-origin by construction, so a preflight
    /// can only come from somebody else's document, and the answer to that is no.
    static func allows(_ method: String, for path: String) -> Bool {
        let readable: Set<String> = [
            ConsoleRoute.index, ConsoleRoute.snapshot, ConsoleRoute.events,
            ConsoleRoute.pairingQR, ConsoleRoute.health,
            // The discovery card is the one capability read a navigation could legitimately
            // want, and it costs a cached answer. `/scan` stays POST-only: it waits.
            ConsoleRoute.discoveryCapabilities
        ]
        switch method {
        case "GET", "HEAD": return readable.contains(path)
        // Every tool is a POST: `availability` and `bookings` are reads, but they are
        // reads that cost an EventKit query, so they get the same method discipline
        // as the writes and no browser can trigger one with a navigation.
        case "POST": return path.hasPrefix(ConsoleRoute.toolPrefix)
            || (!readable.contains(path) && ConsoleRoute.all.contains(path))
        default: return false
        }
    }

    static func allowHeader(for path: String) -> String {
        let readable: Set<String> = [
            ConsoleRoute.index, ConsoleRoute.snapshot, ConsoleRoute.events,
            ConsoleRoute.pairingQR, ConsoleRoute.health, ConsoleRoute.discoveryCapabilities
        ]
        if path.hasPrefix(ConsoleRoute.toolPrefix) { return "POST" }
        return readable.contains(path) ? "GET, HEAD" : "POST"
    }

    // MARK: - Event stream

    private func openEvents(connection: WEBConnection, writer: WEBWriter) async throws {
        let headers: [(String, String)] = [
            ("Content-Type", "text/event-stream; charset=utf-8"),
            ("Cache-Control", "no-cache, no-transform"),
            ("Connection", "keep-alive"),
            ("X-Accel-Buffering", "no")
        ]
        // `retry:` before anything else so a dropped stream reconnects by itself;
        // the page layers exponential backoff on top for when the node is gone.
        try await writer.openStream(headers: headers, preamble: Data("retry: 3000\n\n".utf8))
        let channel = WEBSSEChannel(writer: writer, server: self, connection: connection)
        channels[channel.identifier] = channel
        await connection.track(channel)
        await channel.begin(facade: facade)
    }

    // MARK: - Token

    private func authorized(_ request: WEBHTTPRequest) -> Bool {
        guard !token.isEmpty else { return false }
        // `Digest.matches` is the model layer's constant-time comparison: a
        // loopback server is still a server, and a local process that can time
        // 32 bytes should not be able to read them one at a time.
        if Digest.matches(request.header(NodeWire.consoleTokenHeader) ?? "", token) { return true }
        return Digest.matches(request.queryValue(NodeWire.consoleTokenQuery) ?? "", token)
    }

    // MARK: - Response builders

    private func json<T: Encodable>(_ value: T) throws -> WEBHTTPResponse {
        do {
            return response(try encoder.encode(value), type: "application/json; charset=utf-8", status: 200)
        } catch {
            throw WEBConsoleError.sendFailed("could not encode \(T.self)")
        }
    }

    /// The only way a body reaches the wire: security headers, `Content-Type`,
    /// `Content-Length` and `Cache-Control` are all stamped here.
    private func response(_ body: Data,
                          type: String,
                          status: Int,
                          length: Int? = nil) -> WEBHTTPResponse {
        let payload = body
        var pairs = Self.securityHeaders
        pairs.append(("Cache-Control", "no-store"))
        pairs.append(("Content-Length", String(length ?? payload.count)))
        return WEBHTTPResponse(status: status,
                               reason: Self.reason(for: status),
                               typeHeader: type,
                               headers: pairs,
                               body: payload)
    }

    func failure(_ error: WEBConsoleError, path: String, keepAlive: Bool) -> WEBHTTPResponse {
        let status = error.httpStatus
        let api = path.hasPrefix("/api/") || path.hasPrefix(ConsoleRoute.toolPrefix)
            || path.hasPrefix(ConsoleRoute.discoveryPrefix)
        var pairs = Self.securityHeaders
        pairs.append(("Cache-Control", "no-store"))
        if case .unsupportedMethod = error {
            pairs.append(("Allow", Self.allowHeader(for: path)))
        }
        // A malformed or oversized stream cannot be trusted to still be framed
        // correctly, and a 5xx means we are done with this socket anyway.
        pairs.append(("Connection", keepAlive && status < 500 ? "keep-alive" : "close"))
        let body: Data
        let type: String
        if api {
            body = NodeJSON.encodeLine(WEBErrorBody(error: error.clientMessage, status: status)) ?? Data("{}".utf8)
            type = "application/json; charset=utf-8"
        } else {
            body = Data(error.clientMessage.utf8)
            type = "text/plain; charset=utf-8"
        }
        pairs.append(("Content-Length", String(body.count)))
        return WEBHTTPResponse(status: status,
                               reason: Self.reason(for: status),
                               typeHeader: type,
                               headers: pairs,
                               body: body)
    }

    static func withoutBody(_ response: WEBHTTPResponse) -> WEBHTTPResponse {
        WEBHTTPResponse(status: response.status,
                        reason: response.reason,
                        typeHeader: response.typeHeader,
                        headers: response.headers,
                        body: nil)
    }

    /// Last word on `Connection`, so no route can accidentally promise keep-alive
    /// to a client that asked to hang up.
    static func stampingConnection(_ response: WEBHTTPResponse, keepAlive: Bool) -> WEBHTTPResponse {
        let pairs = response.headers.filter { $0.0.lowercased() != "connection" }
            + [("Connection", keepAlive ? "keep-alive" : "close")]
        return WEBHTTPResponse(status: response.status,
                               reason: response.reason,
                               typeHeader: response.typeHeader,
                               headers: pairs,
                               body: response.body)
    }

    private func decode<T: Decodable>(_ type: T.Type, from request: WEBHTTPRequest) throws -> T {
        guard !request.body.isEmpty else { throw WEBConsoleError.emptyBody }
        do {
            return try decoder.decode(type, from: request.body)
        } catch {
            throw WEBConsoleError.undecodableBody(typeName: String(describing: T.self))
        }
    }

    /// Keeps one QR request from asking CoreImage for an 8K bitmap.
    static func clampedPixelSize(_ raw: String?) -> Int {
        guard let text = raw, let value = Int(text) else { return 512 }
        return min(max(value, 128), 2048)
    }

    /// `/api/snapshot/` and `/api/snapshot` are the same route. Trailing slashes
    /// are the only rewrite: dot segments cannot match a literal, and there is no
    /// filesystem behind any of these strings.
    static func normalisedPath(from raw: String) -> String {
        var text = raw
        while text.count > 1, text.hasSuffix("/") {
            text.removeLast()
        }
        return text.isEmpty ? "/" : text
    }

    static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 302: return "Found"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 411: return "Length Required"
        case 413: return "Content Too Large"
        case 414: return "URI Too Long"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }

    /// RFC 1123 `Date` header, built by hand. A shared `DateFormatter` would be a
    /// non-`Sendable` object living in a static, which is exactly the kind of
    /// thing this file refuses to do.
    static func dateHeader(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT") ?? .gmt
        let parts = calendar.dateComponents([.weekday, .day, .month, .year, .hour, .minute, .second], from: date)
        let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let weekday = weekdays[min(6, max(0, (parts.weekday ?? 1) - 1))]
        let month = months[min(11, max(0, (parts.month ?? 1) - 1))]
        return String(format: "%@, %02d %@ %04d %02d:%02d:%02d GMT",
                      weekday, parts.day ?? 1, month, parts.year ?? 1970,
                      parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    // MARK: - Payload documents

    /// Local `GET /api/health` body: the console's own liveness. The snapshot is
    /// the document of record for anything about the node.
    public struct WEBHealth: Codable, Sendable {
        public let ok: Bool
        public let service: String
        public let version: String
        public let node: String
        public let consolePort: UInt16
        public let loopback: Bool
        public let viewers: Int
        public let uptimeSeconds: Int
        public let serverTime: Date
    }

    public struct WEBStatus: Codable, Sendable {
        public let ok: Bool
        public let detail: String
    }

    struct WEBErrorBody: Codable {
        let error: String
        let status: Int
    }

    struct WEBRevokeRequest: Codable { let publicKey: String }
    struct WEBEngineToggleRequest: Codable { let kind: String; let enabled: Bool }
    struct WEBEngineInvokeRequest: Codable {
        let kind: String
        let action: String
        let payload: [String: JSONValue]?
    }
    struct WEBCommandRequest: Codable { let text: String }
    struct WEBPrivacyAuthorizeResponse: Encodable {
        let ok: Bool
        let detail: String
        let privacy: PrivacyBridgeSnapshot
    }
    struct WEBPrivacyDecisionRequest: Codable {
        let domain: String
        let id: String
        let verb: String
    }
    struct WEBPrivacyDecisionResponse: Encodable {
        let ok: Bool
        let detail: String
        /// The engine's own HTTP-shaped verdict, kept so the panel can tell a stale
        /// proposal (409) apart from a refused one (403) without parsing prose.
        let status: Int
        let privacy: PrivacyBridgeSnapshot
    }
    /// The credential POST body. `secret` is intentionally the only field with no
    /// counterpart in any response or log line: this route's whole contract is that a
    /// value goes in and a *reference* comes out.
    struct WEBHubCredentialRequest: Codable {
        let bridge: String
        let serverId: String
        let secret: String
    }
    struct WEBHubCredentialResponse: Encodable {
        let ok: Bool
        let detail: String
        /// The Keychain reference, never the value. `nil` on a refusal.
        let reference: String?
        let status: Int
    }

    /// `POST /api/update/decision` — only the two owner verbs. `check` takes no
    /// body: there is nothing for the page to choose.
    struct WEBUpdateDecisionRequest: Codable { let verb: String }

    /// `POST /api/godseye/control` — one card action. The verb is checked against
    /// the bridge's own list here and again inside `control`, so an unknown action
    /// dies at the route boundary.
    struct WEBAssistantControlRequest: Codable { let verb: String }
    struct WEBAssistantDecisionRequest: Codable { let id: String; let verb: String }
    /// The secret is decoded only to be handed to the store; no response carries it.
    struct WEBAssistantMailCredentialRequest: Codable { let kind: String; let secret: String }

    struct WEBGodsEyeControlRequest: Codable { let verb: String }

    /// `POST /api/godseye/credential` — the value goes in, a reference comes out.
    /// The source id is one of the fixed `GodsEyeDataSource` raw values.
    struct WEBGodsEyeCredentialRequest: Codable {
        let source: String
        let secret: String
    }
    struct WEBGodsEyeCredentialResponse: Encodable {
        let ok: Bool
        let detail: String
        let reference: String?
        let status: Int
    }

    // MARK: - Dispatch outcome

    enum WEBDispatch: Sendable {
        case response(WEBHTTPResponse)
        /// The socket is an event stream now; the read pump stands down.
        case stream
        /// Nothing to write (cancelled mid-route).
        case nothing
    }

    // MARK: - Incremental parser

    /// One event produced by `WEBWireParser`: a whole request, or the error that
    /// ended this connection.
    enum WEBWireEvent: Sendable {
        case request(WEBHTTPRequest)
        case failure(WEBConsoleError)
    }

    /// Incremental HTTP/1.1 request reader.
    ///
    /// `NWConnection.receive` hands back whatever the kernel happens to hold:
    /// half a request line, three pipelined requests in one read, or byte 4 096
    /// of a 6 MB settings document. This parser therefore owns a buffer plus an
    /// explicit phase and emits a request only once both the head terminator and
    /// `Content-Length` bytes have arrived — one read is never assumed to equal
    /// one request. Every bad input becomes a `WEBWireEvent.failure` value and a
    /// `close`, because a protocol violation desynchronises the stream: there is
    /// no `fatalError` and no precondition in this type, since the input is
    /// untrusted by definition.
    struct WEBWireParser {
        enum Phase {
            case head
            case body
            case dead
        }

        /// The parsed head, held across reads until the body lands.
        private struct Head {
            var method: String
            var target: String
            var path: String
            var query: [URLQueryItem]
            var version: String
            var headers: [String: String]
            var keepAlive: Bool
            var contentLength: Int
        }

        static let headEnd = Data([13, 10, 13, 10])

        private var buffer = Data()
        private var phase: Phase = .head
        private var pending: Head?
        private var expected = 0

        let bodyLimit: Int
        let headLimit: Int
        let targetLimit: Int
        let headerLimit: Int

        init(bodyLimit: Int = LocalWebConsoleServer.maxBodyBytes,
             headLimit: Int = LocalWebConsoleServer.maxHeadBytes,
             targetLimit: Int = LocalWebConsoleServer.maxTargetBytes,
             headerLimit: Int = LocalWebConsoleServer.maxHeaderCount) {
            self.bodyLimit = bodyLimit
            self.headLimit = headLimit
            self.targetLimit = targetLimit
            self.headerLimit = headerLimit
        }

        var isDead: Bool { phase == .dead }

        /// Feeds one TCP segment and returns every message it completed.
        mutating func feed(_ data: Data) -> [WEBWireEvent] {
            var events: [WEBWireEvent] = []
            guard phase != .dead else { return events }
            buffer.append(data)
            while phase != .dead {
                if phase == .head {
                    guard let end = buffer.firstRange(of: Self.headEnd) else {
                        if buffer.count > headLimit {
                            events.append(.failure(.oversizedHead(limitBytes: headLimit)))
                            phase = .dead
                        }
                        return events
                    }
                    let raw = buffer.subdata(in: buffer.startIndex..<end.lowerBound)
                    buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                    rebalance()
                    do {
                        let parsed = try parseHead(raw)
                        if parsed.contentLength == 0 {
                            events.append(.request(Self.message(parsed, body: Data())))
                        } else {
                            pending = parsed
                            expected = parsed.contentLength
                            phase = .body
                        }
                    } catch let error as WEBConsoleError {
                        events.append(.failure(error))
                        phase = .dead
                        return events
                    } catch {
                        events.append(.failure(.malformedHeaders))
                        phase = .dead
                        return events
                    }
                } else {
                    guard let parsed = pending else {
                        phase = .dead
                        return events
                    }
                    guard buffer.count >= expected else { return events }
                    let start = buffer.startIndex
                    let body = buffer.subdata(in: start..<(start + expected))
                    buffer.removeSubrange(start..<(start + expected))
                    rebalance()
                    pending = nil
                    expected = 0
                    phase = .head
                    events.append(.request(Self.message(parsed, body: body)))
                }
            }
            return events
        }

        /// `Data` slices keep their original index space, so normalising after
        /// every removal keeps the `startIndex + count` arithmetic above honest.
        private mutating func rebalance() {
            if buffer.isEmpty {
                buffer.removeAll(keepingCapacity: true)
            } else if buffer.startIndex != 0 {
                buffer = Data(buffer)
            }
        }

        private func parseHead(_ data: Data) throws -> Head {
            guard let text = String(data: data, encoding: .utf8) else {
                throw WEBConsoleError.malformedHeaders
            }
            var lines = text.components(separatedBy: "\r\n")
            guard let requestLine = lines.first, !requestLine.isEmpty else {
                throw WEBConsoleError.malformedHeaders
            }
            lines.removeFirst()
            let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { throw WEBConsoleError.malformedHeaders }
            let method = String(parts[0]).uppercased()
            let target = String(parts[1])
            let version = String(parts[2]).uppercased()
            guard !method.isEmpty, method.allSatisfy({ $0.isLetter }) else {
                throw WEBConsoleError.malformedHeaders
            }
            guard version == "HTTP/1.1" || version == "HTTP/1.0" else {
                throw WEBConsoleError.malformedHeaders
            }
            guard target.utf8.count <= targetLimit else {
                throw WEBConsoleError.targetTooLong(limitBytes: targetLimit)
            }
            guard target.hasPrefix("/"), !target.hasPrefix("//") else {
                // Origin-form only: no absolute-form proxy targets, no
                // authority-form, and `//host/` cannot become an open redirect.
                throw WEBConsoleError.malformedHeaders
            }

            var headers: [String: String] = [:]
            var count = 0
            for line in lines {
                if line.isEmpty { continue }
                guard let colon = line.firstIndex(of: ":") else {
                    throw WEBConsoleError.malformedHeaders
                }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !name.contains(" ") else {
                    throw WEBConsoleError.malformedHeaders
                }
                count += 1
                if count > headerLimit { throw WEBConsoleError.oversizedHead(limitBytes: headLimit) }
                // Duplicate headers fold into one comma list; `Content-Length`
                // consistency is checked after the fold.
                headers[name] = headers[name].map { $0 + ", " + value } ?? value
            }

            if let encoding = headers["transfer-encoding"], !encoding.isEmpty {
                // Chunked bodies would need a second state machine, and no client
                // of this console needs one. Say so instead of guessing.
                throw WEBConsoleError.unsupportedEncoding(encoding)
            }

            var length = 0
            if let declared = headers["content-length"] {
                let values = declared.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard let first = values.first, let parsed = Int(first), parsed >= 0 else {
                    throw WEBConsoleError.malformedHeaders
                }
                guard values.allSatisfy({ Int($0) == parsed }) else {
                    // Two different Content-Length values is request smuggling.
                    throw WEBConsoleError.malformedHeaders
                }
                guard parsed <= bodyLimit else {
                    // Refused at the head: the bytes are never buffered.
                    throw WEBConsoleError.payloadTooLarge(limitBytes: bodyLimit, neededBytes: parsed)
                }
                length = parsed
            } else if Self.methodMayCarryBody(method) {
                throw WEBConsoleError.missingContentLength
            }

            let connection = (headers["connection"] ?? "").lowercased()
            var keepAlive = version == "HTTP/1.1"
            if connection.contains("close") { keepAlive = false }
            if connection.contains("keep-alive") { keepAlive = true }

            let split = Self.split(target)
            return Head(method: method,
                        target: target,
                        path: split.path,
                        query: split.query,
                        version: version,
                        headers: headers,
                        keepAlive: keepAlive,
                        contentLength: length)
        }

        private static func message(_ head: Head, body: Data) -> WEBHTTPRequest {
            WEBHTTPRequest(method: head.method,
                           target: head.target,
                           path: head.path,
                           query: head.query,
                           version: head.version,
                           headers: head.headers,
                           body: body,
                           keepAliveWanted: head.keepAlive)
        }

        static func methodMayCarryBody(_ method: String) -> Bool {
            method == "POST" || method == "PUT" || method == "PATCH"
        }

        static func split(_ target: String) -> (path: String, query: [URLQueryItem]) {
            guard let mark = target.firstIndex(of: "?") else { return (target, []) }
            let path = String(target[..<mark])
            let remainder = String(target[target.index(after: mark)...])
            var items: [URLQueryItem] = []
            for pair in remainder.split(separator: "&", omittingEmptySubsequences: true) {
                let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let rawName = String(pieces[0])
                let rawValue = pieces.count > 1 ? String(pieces[1]) : ""
                items.append(URLQueryItem(name: rawName.removingPercentEncoding ?? rawName,
                                         value: rawValue.isEmpty ? "" : (rawValue.removingPercentEncoding ?? rawValue)))
            }
            return (path, items)
        }
    }

    // MARK: - Write side

    /// The write side of one connection.
    ///
    /// Exactly one `NWConnection.send` is in flight per socket and the un-acked
    /// backlog is capped, so a viewer that stops reading cannot grow the node's
    /// memory. `sendFrame` waits until the kernel has taken the bytes, which is
    /// what gives an event stream real back-pressure instead of an unbounded
    /// queue; a caller that hits the cap gets an error and uses it to drop that
    /// one client rather than stall the pool.
    actor WEBWriter {
        static let backlogLimit = 16 * 1_024 * 1_024

        private let connection: NWConnection
        private var queued: [Data] = []
        private var backlog = 0
        private var writing = false
        private var streaming = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var closed = false

        init(connection: NWConnection) {
            self.connection = connection
        }

        var isClosed: Bool { closed }
        var isStreaming: Bool { streaming }

        /// A complete response: status line, headers, body.
        ///
        /// A keep-alive socket carries several of these, one per request, and the
        /// actor queues a whole response in one step, so two replies can never
        /// interleave head over body. Only an event stream ends the conversation:
        /// once the socket is `text/event-stream` no further response head is legal.
        func send(_ response: WEBHTTPResponse) throws {
            guard !closed, !streaming else { throw WEBConsoleError.writerClosed }
            let chunks = Self.bytes(for: response)
            try enqueue(chunks, bytes: chunks.reduce(0) { $0 + $1.count })
        }

        /// Switches the socket to `text/event-stream`.
        func openStream(headers: [(String, String)], preamble: Data) throws {
            guard !closed, !streaming else { throw WEBConsoleError.writerClosed }
            streaming = true
            let provided = Set(headers.map { $0.0.lowercased() })
            var head = "HTTP/1.1 200 OK\r\n"
            for (name, value) in headers {
                head += "\(name): \(value)\r\n"
            }
            for (name, value) in LocalWebConsoleServer.securityHeaders where !provided.contains(name.lowercased()) {
                head += "\(name): \(value)\r\n"
            }
            // No `Content-Length`, no `Transfer-Encoding`: a stream that simply
            // stays open is exactly how Server-Sent Events is specified.
            head += "Date: \(LocalWebConsoleServer.dateHeader(Date()))\r\n"
            head += "Server: popopx-node-console/1\r\n"
            head += "\r\n"
            let prefix = Data(head.utf8)
            try enqueue([prefix, preamble], bytes: prefix.count + preamble.count)
        }

        /// Writes one SSE frame and waits for the kernel to take it.
        func sendFrame(_ frame: Data) async throws {
            guard streaming, !closed else { throw WEBConsoleError.writerClosed }
            try enqueue([frame], bytes: frame.count)
            if writing || backlog > 0 {
                await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                    waiters.append(waiter)
                }
            }
            guard !closed else { throw WEBConsoleError.writerClosed }
        }

        func close() {
            guard !closed else { return }
            closed = true
            queued.removeAll(keepingCapacity: false)
            backlog = 0
            releaseWaiters()
        }

        /// Drains what is already queued, then closes.
        ///
        /// The socket is cancelled by the connection actor right after this
        /// returns, and `NWConnection.cancel` discards bytes the kernel has not
        /// taken yet. Without this handoff a `Connection: close` response can be
        /// replaced by a reset, which is how a client ends up with a clean
        /// end-of-stream and no reply at all.
        func finish() async {
            guard !closed else { return }
            while writing || !queued.isEmpty {
                await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                    waiters.append(waiter)
                }
                if closed { return }
            }
            close()
        }

        // MARK: plumbing

        private func enqueue(_ chunks: [Data], bytes: Int) throws {
            guard !closed else { throw WEBConsoleError.writerClosed }
            guard backlog + bytes <= Self.backlogLimit else {
                throw WEBConsoleError.sendFailed("write backlog over \(Self.backlogLimit) bytes")
            }
            queued.append(contentsOf: chunks)
            backlog += bytes
            drain()
        }

        private func drain() {
            guard !writing, !closed, !queued.isEmpty else { return }
            let payload = queued.reduce(into: Data()) { $0.append($1) }
            queued.removeAll(keepingCapacity: true)
            let bytes = payload.count
            writing = true
            connection.send(content: payload, completion: .contentProcessed { [weak self] error in
                // Only a `String` crosses the isolation boundary: `NWError` is a
                // struct from an external module and is not annotated `Sendable`.
                let failure = error.map { $0.localizedDescription }
                guard let self else { return }
                Task { await self.settled(failure, bytes: bytes) }
            })
        }

        private func settled(_ failure: String?, bytes: Int) {
            writing = false
            backlog = max(0, backlog - bytes)
            if failure != nil {
                // A failed write is a dead client. Record it, wake anyone waiting
                // on this socket and let the connection actor do the closing.
                closed = true
                queued.removeAll(keepingCapacity: false)
                backlog = 0
                releaseWaiters()
                connection.cancel()
                return
            }
            if queued.isEmpty {
                releaseWaiters()
            } else {
                drain()
            }
        }

        private func releaseWaiters() {
            let pending = waiters
            waiters.removeAll(keepingCapacity: false)
            for waiter in pending { waiter.resume() }
        }

        /// Serialises a response. `Content-Type` comes from the envelope so no
        /// route can contradict itself about what its body is.
        static func bytes(for response: WEBHTTPResponse) -> [Data] {
            var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
            for (name, value) in response.headers where name != "Transfer-Encoding" {
                head += "\(name): \(value)\r\n"
            }
            if let type = response.typeHeader {
                head += "Content-Type: \(type)\r\n"
            }
            head += "Date: \(LocalWebConsoleServer.dateHeader(Date()))\r\n"
            head += "Server: popopx-node-console/1\r\n"
            head += "\r\n"
            var chunks = [Data(head.utf8)]
            if let body = response.body, !response.suppressBody {
                chunks.append(body)
            }
            return chunks
        }
    }

    // MARK: - Connection

    /// One accepted socket: read pump, parser, dispatcher, teardown.
    actor WEBConnection {
        static let readLength = 64 * 1_024
        static let idleNanoseconds = UInt64(75 * 1_000_000_000)

        let identifier = UUID()
        private let connection: NWConnection
        private let server: LocalWebConsoleServer
        private let writer: WEBWriter
        private var parser = WEBWireParser()
        private var channels: [WEBSSEChannel] = []
        private var streamWaiters: [CheckedContinuation<Void, Never>] = []
        private var watchdog: Task<Void, Never>?
        private var open = true
        private var streaming = false
        private var tornDown = false

        init(connection: NWConnection, server: LocalWebConsoleServer) {
            self.connection = connection
            self.server = server
            self.writer = WEBWriter(connection: connection)
        }

        func begin() {
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                Task { await self.observe(state) }
            }
            connection.start(queue: LocalWebConsoleServer.workQueue)
            Task { await self.pump() }
        }

        /// Asks for this socket's teardown (`stop()` path).
        func shutdown() async {
            await teardown()
        }

        func track(_ channel: WEBSSEChannel) {
            channels.append(channel)
        }

        func streamEnded(_ identifier: UUID) {
            channels.removeAll { $0.identifier == identifier }
            if channels.isEmpty { releaseStreamWaiters() }
        }

        /// Wakes the parked read pump once this socket carries no event pipe.
        private func releaseStreamWaiters() {
            guard !streamWaiters.isEmpty else { return }
            let waiting = streamWaiters
            streamWaiters.removeAll(keepingCapacity: false)
            for waiter in waiting { waiter.resume() }
        }

        // MARK: read pump

        private func pump() async {
            while open, !streaming {
                let data: Data
                do {
                    data = try await receive()
                } catch {
                    break
                }
                cancelWatchdog()
                if data.isEmpty { break }
                for event in parser.feed(data) {
                    switch event {
                    case .request(let request):
                        let keepAlive = request.keepAliveWanted
                        let outcome = await server.serve(request, on: self, writer: writer)
                        switch outcome {
                        case .response(let response):
                            do {
                                try await writer.send(response)
                            } catch {
                                open = false
                            }
                            if !keepAlive { open = false }
                        case .stream:
                            // This socket is a one-way event pipe now; the page
                            // opens separate connections for its fetches.
                            streaming = true
                        case .nothing:
                            open = false
                        }
                    case .failure(let error):
                        let response = await server.failure(error, path: "/", keepAlive: false)
                        try? await writer.send(response)
                        open = false
                    }
                    if !open || streaming { break }
                }
            }
            if streaming {
                // An event pipe has no further reads, but the pump is the only task
                // that decides when the socket is let go. Falling into `teardown()`
                // the moment `streaming` was set cancelled the channel that
                // `openEvents` had just built, so the browser received the `retry:`
                // preamble and an immediate end of stream — which is what the page
                // reports as a broken live channel. Park until the last channel on
                // this socket says it is done.
                while !channels.isEmpty {
                    await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                        streamWaiters.append(waiter)
                    }
                }
            }
            await teardown()
        }

        /// One read. `minimumIncompleteLength: 1` means "whatever is there", so a
        /// request may arrive over dozens of calls and several requests may arrive
        /// in one — which is why the parser, not this method, decides what a
        /// request is.
        private func receive() async throws -> Data {
            guard open else { throw WEBConsoleError.connectionClosed }
            armWatchdog()
            let socket = connection
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
                    socket.receive(minimumIncompleteLength: 1, maximumLength: Self.readLength) { data, _, _, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: data ?? Data())
                        }
                    }
                }
            } onCancel: {
                socket.cancel()
            }
        }

        private func armWatchdog() {
            watchdog?.cancel()
            let socket = connection
            watchdog = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: Self.idleNanoseconds)
                } catch {
                    return
                }
                guard let self else { return }
                await self.timedOut(socket)
            }
        }

        private func timedOut(_ socket: NWConnection) {
            // A client that sent half a request and walked away is the cheapest
            // denial of service there is. The budget is 75 idle seconds.
            socket.cancel()
        }

        private func cancelWatchdog() {
            watchdog?.cancel()
            watchdog = nil
        }

        private func observe(_ state: NWConnection.State) async {
            switch state {
            case .ready, .setup, .preparing, .waiting:
                break
            case .failed, .cancelled:
                await teardown()
            @unknown default:
                break
            }
        }

        /// Single teardown path. Cancelling the socket releases the pending read,
        /// which ends the pump, which lands here; `tornDown` makes the re-entry
        /// harmless, and every owned subscription is closed exactly once.
        private func teardown() async {
            guard !tornDown else { return }
            tornDown = true
            open = false
            cancelWatchdog()
            let live = channels
            channels.removeAll(keepingCapacity: false)
            for channel in live { await channel.close() }
            await writer.finish()
            connection.cancel()
            await server.connectionEnded(identifier)
        }
    }

    // MARK: - Event stream

    /// Owns exactly one browser `EventSource` subscription.
    ///
    /// Teardown is the delicate part, so it is done twice on purpose.
    /// `ConsoleEventHub` frees a subscriber slot in the `onTermination` handler of
    /// *its* continuation, which runs when the consumer stops pulling. This type
    /// guarantees that happens: (1) the forwarder task below is the sole consumer
    /// of `facade.events()`, and cancelling it ends its `for await` loop and drops
    /// the hub's iterator, firing `onTermination`; and (2) `close()` also
    /// `finish`es the relay stream this channel owns, which releases the pump.
    /// `close()` is idempotent and runs on write failure, on back-pressure, on
    /// socket cancel, on `stop()` — so a continuation can never outlive the socket
    /// that created it. The relay is bounded, and a `.dropped` yield is treated as
    /// a dead viewer rather than an excuse to grow memory.
    actor WEBSSEChannel {
        static let pendingLimit = 64
        static let tickNanoseconds = UInt64(max(1, Int(NodeWire.heartbeatInterval)) * 1_000_000_000)
        static let pingFrame = Data(": ppx heartbeat\n\n".utf8)

        let identifier = UUID()
        private let writer: WEBWriter
        private let server: LocalWebConsoleServer
        private let connection: WEBConnection
        private var relay: AsyncStream<ConsoleEvent>.Continuation?
        private var tasks: [Task<Void, Never>] = []
        private var closed = false

        init(writer: WEBWriter, server: LocalWebConsoleServer, connection: WEBConnection) {
            self.writer = writer
            self.server = server
            self.connection = connection
        }

        func begin(facade: any NodeConsoleFacade) {
            guard !closed else { return }
            let pipe = AsyncStream<ConsoleEvent>.makeStream(
                bufferingPolicy: .bufferingNewest(Self.pendingLimit)
            )
            relay = pipe.continuation
            let continuation = pipe.continuation
            let stream = pipe.stream
            let writer = self.writer
            let server = self.server
            let connection = self.connection
            let identifier = self.identifier

            // facade stream → bounded relay, so a `finish()` is always in our hands.
            tasks.append(Task {
                for await event in facade.events() {
                    switch continuation.yield(event) {
                    case .enqueued:
                        continue
                    case .dropped:
                        await server.streamDropped(identifier, reason: "back-pressure")
                        continuation.finish()
                        return
                    case .terminated:
                        return
                    @unknown default:
                        continuation.finish()
                        return
                    }
                }
                continuation.finish()
            })

            // relay → socket. One task per viewer: a stalled browser costs this
            // task and nothing else, and the pool keeps serving fetches.
            tasks.append(Task {
                var iterator = stream.makeAsyncIterator()
                while !Task.isCancelled {
                    guard let event = await iterator.next() else { break }
                    do {
                        try await writer.sendFrame(Self.frame(for: event))
                    } catch {
                        break
                    }
                }
                await connection.streamEnded(identifier)
                await server.streamEnded(identifier)
            })

            // A comment frame on the heartbeat interval proves the pipe is alive
            // to the browser, to any proxy in front of it, and to us.
            tasks.append(Task {
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: Self.tickNanoseconds)
                    } catch {
                        return
                    }
                    do {
                        try await writer.sendFrame(Self.pingFrame)
                    } catch {
                        return
                    }
                }
            })
        }

        func close() {
            guard !closed else { return }
            closed = true
            let live = tasks
            tasks.removeAll(keepingCapacity: false)
            for task in live { task.cancel() }
            relay?.finish()
            relay = nil
        }

        /// One `event:`/`data:` frame. The channel name is the SSE event type and
        /// the whole `ConsoleEvent` is the payload, so the page can subscribe per
        /// channel and still see level, message and timestamp.
        static func frame(for event: ConsoleEvent) -> Data {
            var text = "event: \(event.channel.rawValue)\n"
            if let data = NodeJSON.encodeLine(event) {
                // Compact JSON cannot contain a raw newline, but scrubbing keeps a
                // future encoder from being able to break frame boundaries.
                let line = String(decoding: data, as: UTF8.self)
                    .replacingOccurrences(of: "\r", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                text += "data: \(line)\n"
            }
            text += "\n"
            return Data(text.utf8)
        }
    }
}
