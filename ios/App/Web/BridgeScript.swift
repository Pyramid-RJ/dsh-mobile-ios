import Foundation
import DSHBridge

/// The adapter injected at document start, mirroring the Android page contract
/// (docs/03 section 5.1). Kept as a template so the capability list is generated
/// from BridgeCapabilities instead of being hand-maintained in two places.
enum BridgeScript {
    static let handlerName = "dshMobileNative"

    static func make(capabilities: BridgeCapabilities) -> String {
        let values = capabilities.values
        let data = (try? JSONSerialization.data(withJSONObject: values)) ?? Data("[]".utf8)
        let json = String(data: data, encoding: .utf8) ?? "[]"

        return template.replacingOccurrences(of: "__CAPABILITIES__", with: json)
    }

    private static let template = """
    (() => {
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.dshMobileNative;
      if (!handler) { return; }

      const pending = new Map();
      window.__DSH_MOBILE_NATIVE_STATE__ = { pending };

      const deliver = (raw) => {
        let msg;
        try { msg = typeof raw === 'string' ? JSON.parse(raw) : raw; } catch (e) { return; }
        if (!msg || !msg.requestId) { return; }
        const entry = pending.get(msg.requestId);
        if (!entry) { return; }
        pending.delete(msg.requestId);
        clearTimeout(entry.timer);
        if (msg.ok) {
          entry.resolve(msg.value);
        } else {
          const failure = new Error(msg.message || 'bridge error');
          failure.code = msg.code;
          entry.reject(failure);
        }
      };
      window.__DSH_MOBILE_NATIVE_DELIVER__ = deliver;

      const capabilities = __CAPABILITIES__;

      const notify = (event) => {
        try { handler.postMessage(JSON.stringify({ version: 1, event: event })); } catch (e) {}
      };

      window.__DSH_MOBILE_NATIVE__ = {
        capabilities: () => {
          notify('capabilities.requested');
          return Promise.resolve(capabilities.slice());
        },
        invoke: (action, input, options) => new Promise((resolve, reject) => {
          const opts = options || {};
          const requestId = opts.requestId || ('ios-' + Date.now() + '-' + Math.random().toString(36).slice(2));
          const timeoutMs = opts.timeoutMs || 60000;

          const timer = setTimeout(() => {
            pending.delete(requestId);
            const failure = new Error('timeout');
            failure.code = 'timeout';
            reject(failure);
          }, timeoutMs);

          pending.set(requestId, { resolve, reject, timer });

          if (opts.signal) {
            const onAbort = () => {
              if (!pending.has(requestId)) { return; }
              pending.delete(requestId);
              clearTimeout(timer);
              const failure = new Error('cancelled');
              failure.code = 'cancelled';
              reject(failure);
            };
            if (opts.signal.aborted) { onAbort(); } else { opts.signal.addEventListener('abort', onAbort, { once: true }); }
          }

          try {
            handler.postMessage(JSON.stringify({ version: 1, requestId, action, input: input || {} }));
          } catch (e) {
            pending.delete(requestId);
            clearTimeout(timer);
            const failure = new Error('post failed');
            failure.code = 'failed';
            reject(failure);
          }
        })
      };

      notify('bridge.ready');
      window.dispatchEvent(new Event('dsh-mobile-native-ready'));
    })();
    """
}
