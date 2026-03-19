/**
 * smart-display-card.js
 * Custom Lovelace card for Smart Display device control.
 *
 * Config example:
 *   type: custom:smart-display-card
 *   name: Smart Display
 *   state_entity: sensor.smart_display_assistant_state
 *   brightness_entity: number.smart_display_brightness
 *   mute_entity: switch.smart_display_mute
 *   tts_volume_entity: number.smart_display_tts_volume
 *   media_volume_entity: number.smart_display_media_volume
 *   mic_gain_entity: number.smart_display_mic_gain
 *
 * `state_entity` is preferred for the current assistant runtime.
 * `satellite_entity` is still supported for older integrations.
 */

(() => {
  class SmartDisplayCard extends HTMLElement {
    constructor() {
      super();
      this.attachShadow({ mode: 'open' });
      this._config = null;
      this._hass = null;
      this._built = false;
      this._ttsActive = false;
      this._mediaActive = false;
      this._brightnessActive = false;
      this._micActive = false;
    }

    setConfig(config) {
      if (!config.state_entity && !config.satellite_entity) {
        throw new Error('smart-display-card: state_entity or satellite_entity is required');
      }
      this._config = { name: 'Smart Display', ...config };
      if (this._hass) this._ensureBuilt();
    }

    set hass(hass) {
      this._hass = hass;
      this._ensureBuilt();
      this._update();
    }

    getCardSize() {
      let rows = 0;
      for (const key of ['tts_volume_entity', 'media_volume_entity', 'brightness_entity', 'mic_gain_entity']) {
        if (this._config?.[key]) rows += 1;
      }
      return Math.max(2, rows + 1);
    }

    static getStubConfig() {
      return {
        state_entity: 'sensor.smart_display_assistant_state',
        brightness_entity: 'number.smart_display_brightness',
        mute_entity: 'switch.smart_display_mute',
      };
    }

    _ensureBuilt() {
      if (this._built || !this._config || !this._hass) return;
      this._buildDOM();
      this._built = true;
    }

    _buildDOM() {
      this.shadowRoot.innerHTML = `
        <style>${this._css()}</style>
        <ha-card>
          <div class="card-content">
            <div class="header">
              <span class="name">${this._config.name}</span>
              <span class="status-chip" id="chip">
                <span class="dot" id="dot"></span>
                <span id="status-label">Standby</span>
              </span>
            </div>

            ${this._renderSliderRow('tts_volume_entity', 'tts', 'mdi:microphone', 'Assistant', 0, 100, 90)}
            ${this._renderSliderRow('media_volume_entity', 'media', 'mdi:music-note', 'Media', 0, 100, 75)}
            ${this._renderSliderRow('brightness_entity', 'brightness', 'mdi:brightness-6', 'Brightness', 5, 100, 80)}
            ${this._renderSliderRow('mic_gain_entity', 'mic', 'mdi:microphone-settings', 'Mic Sensitivity', 0, 100, 63)}
          </div>
        </ha-card>
      `;

      this._bindEvents();
    }

    _renderSliderRow(configKey, prefix, icon, label, min, max, fallback) {
      const entityId = this._config[configKey];
      if (!entityId) return '';
      const value = this._vol(entityId, fallback);
      return `
        <div class="slider-row">
          <ha-icon icon="${icon}" title="${label}"></ha-icon>
          <span class="label">${label}</span>
          <input type="range" id="${prefix}-slider" min="${min}" max="${max}" value="${value}">
          <span class="vol-val" id="${prefix}-val">${Math.round(value)}%</span>
        </div>
      `;
    }

    _bindEvents() {
      this.shadowRoot.getElementById('chip').addEventListener('click', () => this._chipAction());

      this._bindSlider('tts', 'tts_volume_entity', '_ttsActive');
      this._bindSlider('media', 'media_volume_entity', '_mediaActive');
      this._bindSlider('brightness', 'brightness_entity', '_brightnessActive');
      this._bindSlider('mic', 'mic_gain_entity', '_micActive');
    }

    _bindSlider(prefix, configKey, activeFlag) {
      const entityId = this._config[configKey];
      const slider = this.shadowRoot.getElementById(`${prefix}-slider`);
      const valueEl = this.shadowRoot.getElementById(`${prefix}-val`);
      if (!entityId || !slider || !valueEl) return;

      slider.addEventListener('pointerdown', () => { this[activeFlag] = true; });
      slider.addEventListener('input', (e) => { valueEl.textContent = e.target.value + '%'; });
      slider.addEventListener('change', (e) => {
        this._setNumberValue(entityId, parseInt(e.target.value, 10));
        this[activeFlag] = false;
      });
      slider.addEventListener('pointerup', () => { this[activeFlag] = false; });
    }

    _update() {
      if (!this._built) return;

      const status = this._status();
      const labels = {
        standby: 'Standby',
        listening: 'Listening...',
        responding: 'Responding...',
        muted: 'Muted',
        unknown: 'Unknown',
      };
      const colors = {
        standby: 'var(--secondary-text-color)',
        listening: 'var(--success-color, #4CAF50)',
        responding: 'var(--info-color, #03a9f4)',
        muted: 'var(--warning-color, #FF9800)',
        unknown: 'var(--error-color, #f44336)',
      };
      const color = colors[status] ?? colors.unknown;
      const chip = this.shadowRoot.getElementById('chip');
      const dot = this.shadowRoot.getElementById('dot');
      const label = this.shadowRoot.getElementById('status-label');
      const canMute = !!this._config.mute_entity;
      const muteTitle = status === 'muted' ? 'Tap to unmute' : 'Tap to mute';

      label.textContent = labels[status] ?? status;
      chip.style.color = color;
      chip.style.borderColor = color;
      chip.style.cursor = canMute ? 'pointer' : 'default';
      chip.title = canMute ? muteTitle : '';
      dot.style.background = color;
      dot.classList.toggle('pulse', status !== 'standby' && status !== 'muted' && status !== 'unknown');

      this._syncSlider('tts', this._config.tts_volume_entity, this._ttsActive, 90);
      this._syncSlider('media', this._config.media_volume_entity, this._mediaActive, 75);
      this._syncSlider('brightness', this._config.brightness_entity, this._brightnessActive, 80);
      this._syncSlider('mic', this._config.mic_gain_entity, this._micActive, 63);
    }

    _status() {
      if (this._config.mute_entity) {
        const muteState = this._hass?.states[this._config.mute_entity]?.state;
        if (muteState === 'on') return 'muted';
      }

      const stateEntity = this._config.state_entity || this._config.satellite_entity;
      const state = this._hass?.states[stateEntity]?.state;
      if (!state) return 'unknown';
      if (state === 'idle') return 'standby';
      if (state === 'listening') return 'listening';
      if (state === 'processing' || state === 'responding') return 'responding';
      if (state === 'muted') return 'muted';
      return 'unknown';
    }

    _vol(entityId, fallback) {
      return parseFloat(this._hass?.states[entityId]?.state ?? fallback);
    }

    _syncSlider(prefix, entityId, active, fallback) {
      const slider = this.shadowRoot.getElementById(`${prefix}-slider`);
      const valueEl = this.shadowRoot.getElementById(`${prefix}-val`);
      if (!entityId || !slider || !valueEl || active) return;
      const value = this._vol(entityId, fallback);
      slider.value = value;
      valueEl.textContent = Math.round(value) + '%';
    }

    _chipAction() {
      if (!this._config.mute_entity) return;
      const isMuted = this._hass?.states[this._config.mute_entity]?.state === 'on';
      const service = isMuted ? 'turn_off' : 'turn_on';
      this._hass.callService('switch', service, { entity_id: this._config.mute_entity });
    }

    _setNumberValue(entityId, value) {
      this._hass.callService('number', 'set_value', { entity_id: entityId, value });
    }

    _css() {
      return `
        :host { display: block; }
        .card-content { padding: 16px 16px 10px; }
        .header {
          display: flex;
          align-items: center;
          justify-content: space-between;
          margin-bottom: 18px;
        }
        .name {
          font-size: 1.05em;
          font-weight: 500;
          color: var(--primary-text-color);
        }
        .status-chip {
          display: inline-flex;
          align-items: center;
          gap: 6px;
          padding: 4px 11px;
          border-radius: 14px;
          font-size: 0.8em;
          font-weight: 500;
          border: 1.5px solid;
          transition: color 0.3s, border-color 0.3s, opacity 0.15s;
          user-select: none;
        }
        .status-chip:hover { opacity: 0.72; }
        .dot {
          width: 7px;
          height: 7px;
          border-radius: 50%;
          flex-shrink: 0;
          transition: background 0.3s;
        }
        .dot.pulse { animation: pulse 1.6s ease-in-out infinite; }
        @keyframes pulse {
          0%, 100% { opacity: 1; }
          50% { opacity: 0.2; }
        }
        .slider-row {
          display: flex;
          align-items: center;
          gap: 10px;
          margin-bottom: 14px;
        }
        .label {
          font-size: 0.86em;
          color: var(--secondary-text-color);
          min-width: 62px;
        }
        .vol-val {
          font-size: 0.82em;
          color: var(--secondary-text-color);
          min-width: 36px;
          text-align: right;
        }
        ha-icon {
          color: var(--secondary-text-color);
          --mdc-icon-size: 18px;
          flex-shrink: 0;
        }
        input[type=range] {
          flex: 1;
          height: 4px;
          border-radius: 2px;
          -webkit-appearance: none;
          appearance: none;
          background: var(--secondary-background-color, #e0e0e0);
          outline: none;
          cursor: pointer;
        }
        input[type=range]::-webkit-slider-thumb {
          -webkit-appearance: none;
          width: 18px;
          height: 18px;
          border-radius: 50%;
          background: var(--primary-color);
          cursor: pointer;
          box-shadow: 0 1px 4px rgba(0,0,0,0.25);
        }
        input[type=range]::-moz-range-thumb {
          width: 18px;
          height: 18px;
          border-radius: 50%;
          background: var(--primary-color);
          cursor: pointer;
          border: none;
          box-shadow: 0 1px 4px rgba(0,0,0,0.25);
        }
      `;
    }
  }

  if (!customElements.get('smart-display-card')) {
    customElements.define('smart-display-card', SmartDisplayCard);
  }
})();
