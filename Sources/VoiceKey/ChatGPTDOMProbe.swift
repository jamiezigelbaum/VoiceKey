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

      function describeDOMElement(element) {
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
      }

      function collectDOMElements() {
        return [...document.querySelectorAll('button,[role="button"],a,[aria-label],[data-testid]')];
      }

      function collectElements() {
        return collectDOMElements().map(describeDOMElement);
      }

      // "start voice" overrides the dictation blacklist: the 2026 GPT-Live
      // UI reuses the composer-speech-button testid (historically the
      // dictation mic) for the REAL voice-mode button, labeled "Start
      // Voice" ("Start dictation" is a separate control). Evidence: control
      // inventory 2026-07-24.
      const explicitVoiceStart = (text) => /start voice|voice mode/.test(text);
      const excludedAsDictation = (text) => dictationOnly(text) && !explicitVoiceStart(text);

      function findVoiceStartElement(elements) {
        return elements.find((element) => {
          if (!visible(element)) return false;
          const text = textFor(element);
          if (!hasVoice(text)) return false;
          if (excludedAsDictation(text) || stopIntent(text)) return false;
          return hasStartIntent(text);
        }) || null;
      }

      function findVoiceStartDOMElement() {
        return collectDOMElements().find((element) => {
          const description = describeDOMElement(element);
          if (!visible(description)) return false;
          const text = textFor(description);
          if (!hasVoice(text)) return false;
          if (excludedAsDictation(text) || stopIntent(text)) return false;
          return hasStartIntent(text);
        }) || null;
      }

      function findVoiceStopElement(elements) {
        return elements.find((element) => {
          if (!visible(element)) return false;
          return stopIntent(textFor(element));
        }) || null;
      }

      function findVoiceStopDOMElement() {
        return collectDOMElements().find((element) => {
          const description = describeDOMElement(element);
          if (!visible(description)) return false;
          return stopIntent(textFor(description));
        }) || null;
      }

      function elementAtPoint(x, y) {
        const element = document.elementFromPoint(x, y);
        if (!element) return null;
        const clickable = element.closest('button,[role="button"],a,[aria-label],[data-testid]') || element;
        return pointFor(describeDOMElement(clickable));
      }

      function dispatchClick(element) {
        if (!element) return null;
        const description = describeDOMElement(element);
        const eventInit = {
          bubbles: true,
          cancelable: true,
          view: window,
          clientX: description.x,
          clientY: description.y,
          button: 0,
          buttons: 1
        };
        element.dispatchEvent(new PointerEvent('pointerdown', eventInit));
        element.dispatchEvent(new MouseEvent('mousedown', eventInit));
        element.dispatchEvent(new PointerEvent('pointerup', { ...eventInit, buttons: 0 }));
        element.dispatchEvent(new MouseEvent('mouseup', { ...eventInit, buttons: 0 }));
        element.click();
        return pointFor(description);
      }

      function isLoginRequired(elements, href, bodyText) {
        const currentURL = normalize(href);
        if (currentURL.includes('/auth/login') || currentURL.includes('/login')) return true;
        // The logged-out 2026 shell ships a WORKING composer, so the old
        // "login buttons and no composer" heuristic misses it. The explicit
        // auth-shell markers are authoritative (control inventory
        // 2026-07-24: modal-no-auth-login, login-form, login-button).
        const hasAuthShellMarker = elements.some((element) => hasAny(textFor(element), [
          'modal-no-auth-login',
          'login-form',
          'login-button',
          'signup-button'
        ]));
        if (hasAuthShellMarker) return true;
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
        findVoiceStartDOMElement,
        findVoiceStopElement,
        findVoiceStopDOMElement,
        isLoginRequired,
        isVoiceActive,
        snapshot,
        pointFor,
        elementAtPoint,
        dispatchClick
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

    static let startButtonClickFallbackScript = """
    (() => {
      \(coreScript)
      const elements = VoiceKeyProbe.collectElements();
      const snapshot = VoiceKeyProbe.snapshot(
        elements,
        window.location.href,
        document.body ? document.body.innerText : ''
      );
      if (snapshot.state !== 'ready') return snapshot;
      const element = VoiceKeyProbe.findVoiceStartDOMElement();
      const point = VoiceKeyProbe.dispatchClick(element);
      return point ? { state: 'clicked', x: point.x, y: point.y, label: point.label } : { state: 'needsAttention', reason: 'Could not find a ChatGPT Voice DOM button to click.' };
    })();
    """

    static let stopButtonClickFallbackScript = """
    (() => {
      \(coreScript)
      const element = VoiceKeyProbe.findVoiceStopDOMElement();
      const point = VoiceKeyProbe.dispatchClick(element);
      if (point) return { state: 'clicked', x: point.x, y: point.y, label: point.label };
      return VoiceKeyProbe.snapshot(
        VoiceKeyProbe.collectElements(),
        window.location.href,
        document.body ? document.body.innerText : ''
      );
    })();
    """

    static let voiceToggleClickScript = """
    (() => {
      \(coreScript)
      const stopElement = VoiceKeyProbe.findVoiceStopDOMElement();
      const startElement = VoiceKeyProbe.findVoiceStartDOMElement();
      const point = VoiceKeyProbe.dispatchClick(stopElement || startElement);
      return point ? { state: 'clicked', x: point.x, y: point.y, label: point.label } : { state: 'needsAttention', reason: 'Could not find a ChatGPT Voice toggle button to click.' };
    })();
    """

    /// Logs what the served page ACTUALLY contains when the probe fails —
    /// selector fixes must come from this inventory, never from guessed
    /// labels (the Safari-UA switch changed the served DOM, 2026-07-24).
    static let controlInventoryScript = """
    (() => {
      \(coreScript)
      const labels = VoiceKeyProbe.collectElements()
        .filter((element) => element.visible !== false && element.width > 0 && element.height > 0)
        .map((element) => [element.ariaLabel, element.dataTestId, element.title, (element.text || '').slice(0, 40)]
          .filter(Boolean).join('~'))
        .filter((label) => label.trim().length > 0)
        .slice(0, 40);
      return {
        state: 'inventory',
        title: document.title,
        url: window.location.href,
        labels: labels.join(' | ')
      };
    })();
    """

    static let diagnosticScript = """
    (() => {
      \(coreScript)
      const elements = VoiceKeyProbe.collectElements();
      const snapshot = VoiceKeyProbe.snapshot(
        elements,
        window.location.href,
        document.body ? document.body.innerText : ''
      );
      const start = VoiceKeyProbe.pointFor(VoiceKeyProbe.findVoiceStartElement(elements));
      const stop = VoiceKeyProbe.pointFor(VoiceKeyProbe.findVoiceStopElement(elements));
      return {
        state: snapshot.state,
        reason: snapshot.reason || null,
        startLabel: start ? start.label : null,
        stopLabel: stop ? stop.label : null,
        title: document.title,
        url: window.location.href
      };
    })();
    """
}
