import Foundation

enum ChatGPTDOMProbe {
    static let coreScript = """
    var VoiceKeyProbe = (() => {
      const normalize = (value) => (value || '').toString().replace(/\\s+/g, ' ').trim().toLowerCase();
      const textFor = (element) => normalize([
        element.ariaLabel,
        element.dataTestId,
        element.title,
        element.text,
        element.role
      ].filter(Boolean).join(' '));
      const visible = (element) => element.visible !== false && element.width > 0 && element.height > 0;
      const hasAny = (text, words) => words.some((word) => text.includes(word));
      const hasVoice = (text) => /\\bvoice\\b|voice-mode|voice_mode|voice mode/.test(text);
      const hasStartIntent = (text) => hasAny(text, ['start', 'open', 'begin', 'launch', 'new', 'use']) || hasVoice(text);
      const dictationOnly = (text) => hasAny(text, [
        'dictat',
        'speech to text',
        'transcribe',
        'composer-speech',
        'text input',
        'type with voice',
        'microphone button'
      ]);
      const stopIntent = (text) => hasAny(text, [
        'end voice',
        'exit voice',
        'close voice',
        'stop voice',
        'leave voice',
        'end call',
        'hang up',
        'disconnect',
        'voice-stop',
        'voice_stop',
        'voice-end',
        'voice_end'
      ]);
      const loginIntent = (text) => hasAny(text, ['log in', 'login', 'sign in', 'continue with google', 'continue with microsoft', 'continue with apple']);

      function collectElements() {
        return [...document.querySelectorAll('button,[role="button"],a,[aria-label],[data-testid]')].map((element) => {
          const rect = element.getBoundingClientRect();
          return {
            ariaLabel: element.getAttribute('aria-label'),
            dataTestId: element.getAttribute('data-testid'),
            title: element.getAttribute('title'),
            text: element.textContent,
            role: element.getAttribute('role') || element.tagName,
            visible: !!(rect.width && rect.height),
            x: rect.left + rect.width / 2,
            y: rect.top + rect.height / 2,
            width: rect.width,
            height: rect.height
          };
        });
      }

      function findVoiceStartElement(elements) {
        return elements.find((element) => {
          if (!visible(element)) return false;
          const text = textFor(element);
          if (!hasVoice(text)) return false;
          if (dictationOnly(text) || stopIntent(text)) return false;
          return hasStartIntent(text);
        }) || null;
      }

      function findVoiceStopElement(elements) {
        return elements.find((element) => {
          if (!visible(element)) return false;
          return stopIntent(textFor(element));
        }) || null;
      }

      function isLoginRequired(elements, href, bodyText) {
        const currentURL = normalize(href);
        if (currentURL.includes('/auth/login') || currentURL.includes('/login')) return true;
        const pageText = normalize(bodyText);
        const hasLoginAction = elements.some((element) => visible(element) && loginIntent(textFor(element)));
        const hasComposer = elements.some((element) => hasAny(textFor(element), ['composer', 'send message', 'attach file']));
        return hasLoginAction && !hasComposer && pageText.includes('chatgpt');
      }

      function isVoiceActive(elements, bodyText) {
        if (findVoiceStopElement(elements)) return true;
        const pageText = normalize(bodyText);
        return hasAny(pageText, ['voice mode', 'listening']) && hasAny(pageText, ['end', 'mute', 'transcript']);
      }

      function snapshot(elements, href, bodyText) {
        if (isLoginRequired(elements, href, bodyText)) return { state: 'loginRequired' };
        if (isVoiceActive(elements, bodyText)) return { state: 'voiceActive' };
        if (findVoiceStartElement(elements)) return { state: 'ready' };
        return { state: 'needsAttention', reason: 'Could not find ChatGPT Voice controls.' };
      }

      function pointFor(element) {
        if (!element) return null;
        return { x: element.x, y: element.y, label: textFor(element) };
      }

      return {
        collectElements,
        findVoiceStartElement,
        findVoiceStopElement,
        isLoginRequired,
        isVoiceActive,
        snapshot,
        pointFor
      };
    })();
    """

    static let snapshotScript = """
    (() => {
      \(coreScript)
      return VoiceKeyProbe.snapshot(
        VoiceKeyProbe.collectElements(),
        window.location.href,
        document.body ? document.body.innerText : ''
      );
    })();
    """

    static let startButtonScript = """
    (() => {
      \(coreScript)
      const elements = VoiceKeyProbe.collectElements();
      const snapshot = VoiceKeyProbe.snapshot(
        elements,
        window.location.href,
        document.body ? document.body.innerText : ''
      );
      if (snapshot.state !== 'ready') return snapshot;
      const point = VoiceKeyProbe.pointFor(VoiceKeyProbe.findVoiceStartElement(elements));
      return point ? { state: 'clickable', x: point.x, y: point.y, label: point.label } : snapshot;
    })();
    """

    static let stopButtonScript = """
    (() => {
      \(coreScript)
      const elements = VoiceKeyProbe.collectElements();
      const point = VoiceKeyProbe.pointFor(VoiceKeyProbe.findVoiceStopElement(elements));
      if (point) return { state: 'clickable', x: point.x, y: point.y, label: point.label };
      return VoiceKeyProbe.snapshot(
        elements,
        window.location.href,
        document.body ? document.body.innerText : ''
      );
    })();
    """
}
