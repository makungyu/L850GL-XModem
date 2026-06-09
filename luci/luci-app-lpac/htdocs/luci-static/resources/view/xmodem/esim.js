'use strict';
'require view';
'require ui';
'require dom';
'require request';
'require rpc';
'require poll';

var DIAL_STATE_POLL_INTERVAL = 10;

/*
 * XModem Next - eSIM Manager View
 * 
 * This is a thin wrapper that loads the luci-app-lpac interface
 * inside the xmodem-next tab system. The actual eSIM management logic
 * lives in /luci-static/resources/lpac-esim/js/*.js and communicates
 * with the rpcd/ubus backend at object lpac_esim.
 */

return view.extend({
	render: function() {
		var container = E('div', { 'class': 'cbi-map' });

		// Header
		container.appendChild(E('h2', {}, [
			_('eSIM Manager'),
			' ',
			E('span', {
				'id': 'esim-connectivity-status',
				'title': _('Checking dial status...'),
				'style': 'display: inline-block; width: 12px; height: 12px; border-radius: 50%; background-color: #999; vertical-align: middle;'
			}, '')
		]));
		container.appendChild(E('div', { 'class': 'cbi-map-descr' },
			[ _('Manage eSIM profiles via lpac. Supports profile list, switch, download, and delete.'), ' ', E('span', { 'id': 'esim-app-version' }, '') ]));

		// Tab menu
		var tabMenu = E('ul', { 'class': 'cbi-tabmenu', 'id': 'esim-subtabs' });
		var tabs = [
			{ id: 'info-tab', label: _('Info') },
			{ id: 'profiles-tab', label: _('Profiles') },
			{ id: 'download-tab', label: _('Downloads') },
			{ id: 'notifications-tab', label: _('Notif') },
			{ id: 'config-tab', label: _('Config') },
			{ id: 'telegram-tab', label: _('TgBot') }
		];

		tabs.forEach(function(tab, idx) {
			var li = E('li', { 'class': idx === 0 ? 'cbi-tab' : 'cbi-tab-disabled' });
			li.appendChild(E('a', { 'href': '#', 'data-tab': tab.id, 'click': function(ev) {
				ev.preventDefault();
				showEsimTab(tab.id, this);
			}}, tab.label));
			tabMenu.appendChild(li);
		});
		container.appendChild(tabMenu);

		// Lock banner
		container.appendChild(E('div', { 'id': 'esim-lock-banner', 'style': 'display: none; margin-bottom: 20px; padding: 10px; border: 1px solid #17a2b8; background: #d1ecf1; border-radius: 4px; color: #0c5460;' },
			[ E('strong', {}, _('Backend is busy')), ' — ', E('span', { 'id': 'esim-lock-text' }, _('An operation is in progress...')) ]));

		// Tab content container - will be populated by lpac-esim JS
		var tabContainer = E('div', { 'class': 'cbi-tabcontainer', 'id': 'esim-tab-container' });

		tabs.forEach(function(tab, idx) {
			var div = E('div', {
				'id': tab.id,
				'class': 'cbi-tabcontent' + (idx === 0 ? ' cbi-tabcontent-active' : ''),
				'style': idx === 0 ? '' : 'display: none;'
			});
			div.innerHTML = getEsimTabContent(tab.id);
			tabContainer.appendChild(div);
		});
		container.appendChild(tabContainer);

		// Load CSS
		var cssLink = document.createElement('link');
		cssLink.rel = 'stylesheet';
		cssLink.href = L.resource('lpac-esim/css/lpac-esim.css');
		document.head.appendChild(cssLink);

		// After DOM is ready, load the eSIM JS modules
		requestAnimationFrame(function() {
			window.esimLuciUi = ui;
			loadEsimModules();
		});

		return container;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});

// Tab switching
function showEsimTab(tabId, el) {
	// Hide all tabs
	var tabs = document.querySelectorAll('#esim-tab-container .cbi-tabcontent');
	tabs.forEach(function(t) { t.style.display = 'none'; t.classList.remove('cbi-tabcontent-active'); });

	// Deactivate all tab links
	var links = document.querySelectorAll('#esim-subtabs li');
	links.forEach(function(l) {
		l.classList.remove('cbi-tab');
		l.classList.add('cbi-tab-disabled');
	});

	// Show selected tab
	var target = document.getElementById(tabId);
	if (target) {
		target.style.display = '';
		target.classList.add('cbi-tabcontent-active');
	}

	loadEsimTab(tabId);

	// Activate clicked tab
	if (el && el.parentNode) {
		el.parentNode.classList.remove('cbi-tab-disabled');
		el.parentNode.classList.add('cbi-tab');
	}
}

function loadScriptsSequentially(scripts, done) {
	var index = 0;

	function next() {
		if (index >= scripts.length) {
			if (typeof done === 'function') done();
			return;
		}

		var script = document.createElement('script');
		script.src = L.resource(scripts[index++]);
		script.onload = next;
		script.onerror = next;
		document.body.appendChild(script);
	}

	next();
}

function loadEsimTab(tabId) {
	window.tabLoaded = window.tabLoaded || {};
	if (window.tabLoaded[tabId]) return;
	window.tabLoaded[tabId] = true;

	switch (tabId) {
	case 'info-tab':
		if (typeof loadESIMInfo === 'function') loadESIMInfo();
		break;
	case 'profiles-tab':
		if (typeof loadProfiles === 'function') loadProfiles();
		break;
	case 'notifications-tab':
		if (typeof loadNotifications === 'function') loadNotifications();
		break;
	case 'config-tab':
		if (typeof loadConfig === 'function') loadConfig();
		break;
	case 'telegram-tab':
		if (typeof loadTelegramConfig === 'function') loadTelegramConfig();
		if (typeof checkBotStatus === 'function') checkBotStatus();
		break;
	}
}

function getEsimTabContent(tabId) {
	var content = {
	"info-tab": "<div id=\"esim-info-loading\" style=\"text-align: center; padding: 20px;\">\n    Loading eSIM information...\n</div>\n\n<div id=\"esim-info-content\" style=\"display: none;\">\n    <fieldset class=\"cbi-section esim-collapsible-section\">\n        <legend class=\"esim-section-toggle\" onclick=\"toggleESIMInfoSection(this)\"><span>Basic Information</span><span class=\"esim-section-caret\">&#9660;</span></legend>\n        <table class=\"cbi-section-table esim-section-body\">\n            <tr>\n                <td style=\"width: 200px; font-weight: bold;\">EID:</td>\n                <td id=\"esim-eid\">-</td>\n            </tr>\n            <tr>\n                <td style=\"font-weight: bold;\">Profile Version:</td>\n                <td id=\"esim-profile-version\">-</td>\n            </tr>\n            <tr>\n                <td style=\"font-weight: bold;\">SVN:</td>\n                <td id=\"esim-svn\">-</td>\n            </tr>\n            <tr>\n                <td style=\"font-weight: bold;\">Firmware Version:</td>\n                <td id=\"esim-firmware\">-</td>\n            </tr>\n            <tr>\n                <td style=\"font-weight: bold;\">Default SM-DP+ Address:</td>\n                <td id=\"esim-smdp\">-</td>\n            </tr>\n            <tr>\n                <td style=\"font-weight: bold;\">Root SM-DS Address:</td>\n                <td id=\"esim-smds\">-</td>\n            </tr>\n        </table>\n    </fieldset>\n\n    <fieldset class=\"cbi-section esim-collapsible-section\">\n        <legend class=\"esim-section-toggle\" onclick=\"toggleESIMInfoSection(this)\"><span>Memory Information</span><span class=\"esim-section-caret\">&#9660;</span></legend>\n        <table class=\"cbi-section-table esim-section-body\">\n            <tr>\n                <td style=\"width: 200px; font-weight: bold;\">Free Non-Volatile Memory:</td>\n                <td id=\"esim-nv-memory\">-</td>\n            </tr>\n            <tr>\n                <td style=\"font-weight: bold;\">Free Volatile Memory:</td>\n                <td id=\"esim-v-memory\">-</td>\n            </tr>\n            <tr>\n                <td style=\"font-weight: bold;\">Installed Applications:</td>\n                <td id=\"esim-apps\">-</td>\n            </tr>\n        </table>\n    </fieldset>\n\n    \n    <fieldset class=\"cbi-section esim-collapsible-section\">\n        <legend class=\"esim-section-toggle\" onclick=\"toggleESIMInfoSection(this)\"><span>Modem Status</span><span class=\"esim-section-caret\">&#9660;</span></legend>\n        <table class=\"cbi-section-table esim-section-body\">\n            <tr>\n                <td style=\"width: 200px; font-weight: bold;\">Model:</td>\n                <td id=\"modem-model\">-</td>\n            </tr>\n            <tr>\n                <td style=\"font-weight: bold;\">Operator:</td>\n                <td id=\"modem-operator\">-</td>\n            </tr>\n            <tr>\n                <td style=\"font-weight: bold;\">Technology:</td>\n                <td id=\"modem-technology\">-</td>\n            </tr>\n            <tr>\n                <td style=\"font-weight: bold;\">Signal:</td>\n                <td id=\"modem-signal\">-</td>\n            </tr>\n            <tr>\n                <td style=\"font-weight: bold;\">State:</td>\n                <td id=\"modem-state\">-</td>\n            </tr>\n        </table>\n    </fieldset>\n</div>\n\n<div id=\"esim-info-error\" style=\"display: none; color: red; padding: 10px;\">\n    <strong>Error:</strong> <span id=\"esim-error-message\"></span>\n</div>\n\n<div class=\"cbi-page-custom-actions\">\n    <input type=\"button\" class=\"cbi-button cbi-button-apply\" value=\"Refresh\" onclick=\"loadESIMInfo()\" />\n</div>",
	"profiles-tab": "<div id=\"profiles-loading\" style=\"text-align: center; padding: 20px;\">\n    Loading profiles...\n</div>\n\n<div id=\"profiles-content\" style=\"display: none;\">\n    <fieldset class=\"cbi-section\">\n        <legend>Installed Profiles</legend>\n        <div class=\"cbi-section-node\">\n            <div class=\"table-responsive\">\n                <table class=\"cbi-section-table\" id=\"profiles-table\">\n                    <thead>\n                        <tr class=\"cbi-section-table-titles\">\n                            <th class=\"cbi-section-table-cell\">Profile Name</th>\n                            <th class=\"cbi-section-table-cell\">ICCID</th>\n                            <th class=\"cbi-section-table-cell\">Provider</th>\n                            <th class=\"cbi-section-table-cell\" style=\"text-align: center;\">Status</th>\n                            <th class=\"cbi-section-table-cell\" style=\"text-align: center; min-width: 200px;\">Actions</th>\n                        </tr>\n                    </thead>\n                    <tbody id=\"profiles-tbody\">\n                    </tbody>\n                </table>\n            </div>\n\n            <div id=\"no-profiles\" style=\"display: none; text-align: center; padding: 20px; color: #666;\">\n                No profiles installed\n            </div>\n        </div>\n    </fieldset>\n</div>\n\n<div id=\"profiles-error\" style=\"display: none; color: red; padding: 10px;\">\n    <strong>Error:</strong> <span id=\"profiles-error-message\"></span>\n</div>\n\n<div id=\"profile-notifications-status\" style=\"margin-top: 20px;\">\n    <div id=\"profile-notifications-success\" style=\"display: none; color: green; padding: 10px; border: 1px solid #5cb85c; background: #dff0d8; border-radius: 4px;\">\n        <strong>Status:</strong> <span id=\"profile-notifications-success-message\"></span>\n    </div>\n    <div id=\"profile-notifications-error\" style=\"display: none; color: #d9534f; padding: 10px; border: 1px solid #d9534f; background: #f2dede; border-radius: 4px;\">\n        <strong>Error:</strong> <span id=\"profile-notifications-error-message\"></span>\n    </div>\n</div>\n\n<div class=\"cbi-page-custom-actions\">\n    <input type=\"button\" class=\"cbi-button cbi-button-apply\" value=\"Refresh\" onclick=\"loadProfiles()\" />\n    <input type=\"button\" class=\"cbi-button cbi-button-reset\" value=\"Reboot Modem\" onclick=\"rebootModem()\" />\n</div>",
	"download-tab": "<fieldset class=\"cbi-section\">\n    <legend>QR Code Upload</legend>\n    <div class=\"cbi-section-node\">\n        <div class=\"cbi-value\">\n            <label class=\"cbi-value-title\">QR Code Image:</label>\n            <div class=\"cbi-value-field\">\n                <input type=\"file\" id=\"qr-file\" accept=\"image/*\" onchange=\"handleQRFile(this)\" class=\"cbi-input-file\" />\n                <div class=\"cbi-value-description\">Upload a JPG or PNG image containing the eSIM QR code</div>\n            </div>\n        </div>\n\n        <div id=\"qr-preview-container\" style=\"display: none; margin-top: 15px;\">\n            <div class=\"cbi-value\">\n                <label class=\"cbi-value-title\">Preview:</label>\n                <div class=\"cbi-value-field\">\n                    <div style=\"display: inline-block; vertical-align: top;\">\n                        <img id=\"qr-preview\" style=\"max-width: 300px; max-height: 200px; border: 1px solid #ccc; border-radius: 4px; display: block;\" />\n                        <div id=\"qr-decode-status\" style=\"margin-top: 8px;\">\n                            <div id=\"qr-decode-loading\" style=\"display: none; color: #0099cc;\">Decoding QR code...</div>\n                            <div id=\"qr-decode-success\" style=\"display: none; color: green;\"><strong>QR decoded!</strong></div>\n                            <div id=\"qr-decode-error\" style=\"display: none; color: red;\"><span id=\"qr-decode-error-message\"></span></div>\n                        </div>\n                        <button type=\"button\" class=\"cbi-button cbi-button-reset\" onclick=\"clearQRUpload()\" style=\"margin-top: 10px;\">Clear</button>\n                    </div>\n                </div>\n            </div>\n        </div>\n    </div>\n</fieldset>\n\n<fieldset class=\"cbi-section\">\n    <legend>Activation Code (LPA string or manual)</legend>\n    <div class=\"cbi-section-node\">\n        <div class=\"cbi-value\">\n            <label class=\"cbi-value-title\">LPA String:</label>\n            <div class=\"cbi-value-field\">\n                <input type=\"text\" id=\"lpa-activation-code\" class=\"cbi-input-text\" placeholder=\"LPA:1$smdp.example.com$MATCHING-ID\" />\n                <div class=\"cbi-value-description\">Full LPA string (from QR or pasted). Takes precedence over manual fields below.</div>\n            </div>\n        </div>\n        <div class=\"cbi-value\">\n            <label class=\"cbi-value-title\">SM-DP+ Server:</label>\n            <div class=\"cbi-value-field\">\n                <input type=\"text\" id=\"smdp-server\" class=\"cbi-input-text\" placeholder=\"smdp.example.com\" />\n            </div>\n        </div>\n        <div class=\"cbi-value\">\n            <label class=\"cbi-value-title\">Matching ID:</label>\n            <div class=\"cbi-value-field\">\n                <input type=\"text\" id=\"matching-id\" class=\"cbi-input-text\" placeholder=\"QR-G-5C-1LS-XXXXX\" />\n            </div>\n        </div>\n        <div class=\"cbi-value\">\n            <label class=\"cbi-value-title\">Confirmation Code:</label>\n            <div class=\"cbi-value-field\">\n                <input type=\"text\" id=\"confirmation-code\" class=\"cbi-input-text\" placeholder=\"Optional\" />\n            </div>\n        </div>\n    </div>\n</fieldset>\n\n<div id=\"download-status\" style=\"margin-top: 20px;\">\n    <div id=\"download-loading\" style=\"display: none; padding: 15px; border: 1px solid #17a2b8; background: #d1ecf1; border-radius: 4px; color: #0c5460;\">\n        <strong>Downloading profile...</strong> This may take 1-2 minutes. Do not close this page.\n    </div>\n    <div id=\"download-success\" style=\"display: none; color: green; padding: 10px; border: 1px solid #5cb85c; background: #dff0d8; border-radius: 4px;\">\n        <strong>Success:</strong> <span id=\"download-success-message\"></span>\n    </div>\n    <div id=\"download-error\" style=\"display: none; color: #d9534f; padding: 10px; border: 1px solid #d9534f; background: #f2dede; border-radius: 4px;\">\n        <strong>Error:</strong> <span id=\"download-error-message\"></span>\n    </div>\n</div>\n\n<div class=\"cbi-page-custom-actions\">\n    <input type=\"button\" class=\"cbi-button cbi-button-apply\" value=\"Download Profile\" onclick=\"downloadProfile()\" />\n    <input type=\"button\" class=\"cbi-button cbi-button-reset\" value=\"Clear\" onclick=\"clearDownloadForm()\" />\n</div>",
	"notifications-tab": "<div id=\"notifications-loading\" style=\"text-align: center; padding: 20px;\">\n    Loading notifications...\n</div>\n\n<div id=\"notifications-content\" style=\"display: none;\">\n    <fieldset class=\"cbi-section\">\n        <legend>Pending Notifications</legend>\n        <div class=\"cbi-section-node\">\n            <div class=\"table-responsive\">\n                <table class=\"cbi-section-table\" id=\"notifications-table\">\n                    <thead>\n                        <tr class=\"cbi-section-table-titles\">\n                            <th class=\"cbi-section-table-cell\">Sequence</th>\n                            <th class=\"cbi-section-table-cell\">ICCID</th>\n                            <th class=\"cbi-section-table-cell\">Operation</th>\n                            <th class=\"cbi-section-table-cell\">Server</th>\n                        </tr>\n                    </thead>\n                    <tbody id=\"notifications-tbody\">\n                    </tbody>\n                </table>\n            </div>\n\n            <div id=\"no-notifications\" style=\"display: none; text-align: center; padding: 20px; color: #666;\">\n                No pending notifications\n            </div>\n        </div>\n    </fieldset>\n</div>\n\n<div id=\"notifications-error\" style=\"display: none; color: red; padding: 10px;\">\n    <strong>Error:</strong> <span id=\"notifications-error-message\"></span>\n</div>\n\n<div id=\"notification-status\" style=\"margin-top: 20px;\">\n    <div id=\"notifications-success\" style=\"display: none; color: green; padding: 10px; border: 1px solid #5cb85c; background: #dff0d8; border-radius: 4px;\">\n        <strong>Status:</strong> <span id=\"notifications-success-message\"></span>\n    </div>\n</div>\n\n<div class=\"cbi-page-custom-actions\">\n    <input type=\"button\" class=\"cbi-button cbi-button-apply\" value=\"Process & Remove All\" onclick=\"processAllNotifications()\" />\n    <input type=\"button\" class=\"cbi-button cbi-button-remove\" value=\"Clear All (Offline)\" onclick=\"clearNotifications()\" />\n    <input type=\"button\" class=\"cbi-button cbi-button-reset\" value=\"Refresh\" onclick=\"loadNotifications()\" />\n</div>",
	"config-tab": "<div id=\"config-loading\" style=\"text-align: center; padding: 20px;\">\n    Loading configuration...\n</div>\n\n<div id=\"config-content\" style=\"display: none;\">\n    <fieldset class=\"cbi-section\">\n        <legend>APDU Backend</legend>\n        <div class=\"cbi-section-node\">\n            <div class=\"cbi-value\">\n                <label class=\"cbi-value-title\">Backend Type</label>\n                <div class=\"cbi-value-field\">\n                    <select id=\"cfg-apdu-backend\" class=\"cbi-input-select\" onchange=\"onBackendChange()\">\n                        <option value=\"qmi\">QMI</option>\n                        <option value=\"at\">AT</option>\n                        <option value=\"mbim\">MBIM</option>\n                    </select>\n                    <div class=\"cbi-value-description\">QMI is primary, AT is fallback. MBIM pending lpac recompilation.</div>\n                </div>\n            </div>\n        </div>\n    </fieldset>\n\n    <fieldset class=\"cbi-section\">\n        <legend>Device Settings</legend>\n        <div class=\"cbi-section-node\">\n            <div class=\"cbi-value\" id=\"cfg-qmi-device-row\">\n                <label class=\"cbi-value-title\">QMI Device</label>\n                <div class=\"cbi-value-field\">\n                    <input type=\"text\" id=\"cfg-qmi-device\" class=\"cbi-input-text\" placeholder=\"/dev/cdc-wdm0\" />\n                </div>\n            </div>\n            <div class=\"cbi-value\" id=\"cfg-qmi-slot-row\">\n                <label class=\"cbi-value-title\">QMI SIM Slot</label>\n                <div class=\"cbi-value-field\">\n                    <select id=\"cfg-qmi-slot\" class=\"cbi-input-select\">\n                        <option value=\"1\">Slot 1</option>\n                        <option value=\"2\">Slot 2</option>\n                    </select>\n                </div>\n            </div>\n            <div class=\"cbi-value\" id=\"cfg-at-device-row\">\n                <label class=\"cbi-value-title\">AT Device</label>\n                <div class=\"cbi-value-field\">\n                    <input type=\"text\" id=\"cfg-at-device\" class=\"cbi-input-text\" placeholder=\"/dev/ttyUSB3\" />\n                </div>\n            </div>\n            <div class=\"cbi-value\" id=\"cfg-mbim-device-row\" style=\"display: none;\">\n                <label class=\"cbi-value-title\">MBIM Device</label>\n                <div class=\"cbi-value-field\">\n                    <input type=\"text\" id=\"cfg-mbim-device\" class=\"cbi-input-text\" placeholder=\"/dev/cdc-wdm0\" />\n                </div>\n            </div>\n            <div class=\"cbi-value\" id=\"cfg-mbim-proxy-row\" style=\"display: none;\">\n                <label class=\"cbi-value-title\">MBIM Proxy</label>\n                <div class=\"cbi-value-field\">\n                    <select id=\"cfg-mbim-proxy\" class=\"cbi-input-select\">\n                        <option value=\"0\">Disabled</option>\n                        <option value=\"1\">Enabled</option>\n                    </select>\n                </div>\n            </div>\n        </div>\n    </fieldset>\n\n    <fieldset class=\"cbi-section\">\n        <legend>Modem Reboot</legend>\n        <div class=\"cbi-section-node\">\n            <div class=\"cbi-value\">\n                <label class=\"cbi-value-title\">Reboot Method</label>\n                <div class=\"cbi-value-field\">\n                    <select id=\"cfg-reboot-method\" class=\"cbi-input-select\">\n                        <option value=\"script\">Auto (script cascade: QMI → AT → USB)</option>\n                    </select>\n                    <div class=\"cbi-value-description\">lpac-esim handles reboot automatically with 3-level cascade.</div>\n                </div>\n            </div>\n        </div>\n    </fieldset>\n\n    <fieldset class=\"cbi-section\">\n        <legend>Debug</legend>\n        <div class=\"cbi-section-node\">\n            <div class=\"cbi-value\">\n                <label class=\"cbi-value-title\">APDU Debug</label>\n                <div class=\"cbi-value-field\">\n                    <select id=\"cfg-apdu-debug\" class=\"cbi-input-select\">\n                        <option value=\"0\">Disabled</option>\n                        <option value=\"1\">Enabled</option>\n                    </select>\n                </div>\n            </div>\n            <div class=\"cbi-value\">\n                <label class=\"cbi-value-title\">HTTP Debug</label>\n                <div class=\"cbi-value-field\">\n                    <select id=\"cfg-http-debug\" class=\"cbi-input-select\">\n                        <option value=\"0\">Disabled</option>\n                        <option value=\"1\">Enabled</option>\n                    </select>\n                </div>\n            </div>\n            <div class=\"cbi-value\">\n                <label class=\"cbi-value-title\">AT Debug</label>\n                <div class=\"cbi-value-field\">\n                    <select id=\"cfg-at-debug\" class=\"cbi-input-select\">\n                        <option value=\"0\">Disabled</option>\n                        <option value=\"1\">Enabled</option>\n                    </select>\n                </div>\n            </div>\n        </div>\n    </fieldset>\n\n    <div class=\"cbi-page-custom-actions\">\n        <input type=\"button\" class=\"cbi-button cbi-button-apply\" value=\"Save & Apply\" onclick=\"saveConfig()\" />\n        <input type=\"button\" class=\"cbi-button cbi-button-reset\" value=\"Reset\" onclick=\"loadConfig()\" />\n    </div>\n</div>\n\n<div id=\"config-error\" style=\"display: none; color: red; padding: 10px;\">\n    <strong>Error:</strong> <span id=\"config-error-message\"></span>\n</div>\n\n<div id=\"config-success\" style=\"display: none; color: green; padding: 10px;\">\n    <strong>Success:</strong> <span id=\"config-success-message\"></span>\n</div>",
	"telegram-tab": "<div id=\"telegram-loading\" style=\"text-align: center; padding: 20px;\">\n    Loading Telegram Bot configuration...\n</div>\n\n<div id=\"telegram-content\" style=\"display: none;\">\n    <fieldset class=\"cbi-section\">\n        <legend>Bot Settings</legend>\n        <div class=\"cbi-section-node\">\n            <div class=\"cbi-value\">\n                <label class=\"cbi-value-title\">Enable Bot</label>\n                <div class=\"cbi-value-field\">\n                    <input type=\"checkbox\" id=\"tg-enabled\" class=\"cbi-input-checkbox\" />\n                    <button type=\"button\" class=\"cbi-button cbi-button-action\" id=\"tg-test-btn\" style=\"margin-left: 12px;\">Test Connection</button>\n                    <button type=\"button\" class=\"cbi-button cbi-button-apply\" id=\"tg-apply-bot-btn\" style=\"margin-left: 8px;\">Apply</button>\n                    <div class=\"cbi-value-description\">Start Telegram bot service on boot. Click Apply to save bot settings.</div>\n                </div>\n            </div>\n            <div class=\"cbi-value\">\n                <label class=\"cbi-value-title\">Bot Token</label>\n                <div class=\"cbi-value-field\">\n                    <input type=\"text\" id=\"tg-token\" class=\"cbi-input-text\" placeholder=\"123456789:ABCdefGHI-jklMNOpqrSTUvwxYZ\" style=\"width: 100%;\" />\n                    <div class=\"cbi-value-description\">Get from @BotFather on Telegram</div>\n                </div>\n            </div>\n            <div class=\"cbi-value\">\n                <label class=\"cbi-value-title\">Chat ID</label>\n                <div class=\"cbi-value-field\">\n                    <input type=\"text\" id=\"tg-chat-id\" class=\"cbi-input-text\" placeholder=\"987654321\" />\n                    <div class=\"cbi-value-description\">Your Telegram user/group ID. Get from @userinfobot</div>\n                </div>\n            </div>\n            <div class=\"cbi-value\">\n                <label class=\"cbi-value-title\">Poll Interval</label>\n                <div class=\"cbi-value-field\">\n                    <input type=\"number\" id=\"tg-poll-interval\" class=\"cbi-input-text\" value=\"1\" min=\"1\" max=\"300\" style=\"width: 80px;\" />\n                    <span> seconds</span>\n                </div>\n            </div>\n        </div>\n    </fieldset>\n\n    <fieldset class=\"cbi-section\">\n        <legend>Security</legend>\n        <div class=\"cbi-section-node\">\n            <div class=\"cbi-value\">\n                <label class=\"cbi-value-title\">Allow Disruptive</label>\n                <div class=\"cbi-value-field\">\n                    <input type=\"checkbox\" id=\"tg-allow-disruptive\" class=\"cbi-input-checkbox\" checked />\n                    <div class=\"cbi-value-description\">Allow profile switch, delete, and reboot via Telegram</div>\n                </div>\n            </div>\n            <div class=\"cbi-value\">\n                <label class=\"cbi-value-title\">Require Confirmation</label>\n                <div class=\"cbi-value-field\">\n                    <input type=\"checkbox\" id=\"tg-require-confirm\" class=\"cbi-input-checkbox\" checked />\n                    <div class=\"cbi-value-description\">Ask for confirmation before disruptive operations</div>\n                    <div style=\"margin-top: 8px;\">\n                        <button type=\"button\" class=\"cbi-button cbi-button-apply\" id=\"tg-apply-security-btn\">Apply</button>\n                    </div>\n                </div>\n            </div>\n        </div>\n    </fieldset>\n\n    <fieldset class=\"cbi-section\">\n        <legend>Status</legend>\n        <div class=\"cbi-section-node\">\n            <div class=\"cbi-value\">\n                <label class=\"cbi-value-title\">Bot Status</label>\n                <div class=\"cbi-value-field\">\n                    <span id=\"tg-status-indicator\">⏳ Checking...</span><br /><small>Last poll: <span id=\"tg-last-poll\">-</span></small>\n                </div>\n            </div>\n        </div>\n    </fieldset>\n\n    <fieldset class=\"cbi-section\">\n        <legend>Available Commands</legend>\n        <div class=\"cbi-section-node\">\n            <table class=\"table\" style=\"width: 100%;\">\n                <tr class=\"tr\"><td class=\"td\"><code>/status</code></td><td class=\"td\">Modem info & signal</td></tr>\n                <tr class=\"tr\"><td class=\"td\"><code>/eid</code></td><td class=\"td\">Show eUICC EID</td></tr>\n                <tr class=\"tr\"><td class=\"td\"><code>/profiles</code></td><td class=\"td\">List eSIM profiles</td></tr>\n                <tr class=\"tr\"><td class=\"td\"><code>/enable &lt;ICCID&gt;</code></td><td class=\"td\">Switch active profile</td></tr>\n                <tr class=\"tr\"><td class=\"td\"><code>/download &lt;LPA&gt;</code></td><td class=\"td\">Download new profile</td></tr>\n                <tr class=\"tr\"><td class=\"td\"><code>/delete &lt;ICCID&gt;</code></td><td class=\"td\">Delete profile</td></tr>\n                <tr class=\"tr\"><td class=\"td\"><code>/reboot</code></td><td class=\"td\">Restart modem</td></tr>\n                <tr class=\"tr\"><td class=\"td\"><code>/notif</code></td><td class=\"td\">Process notifications</td></tr>\n                <tr class=\"tr\"><td class=\"td\"><code>/help</code></td><td class=\"td\">Show all commands</td></tr>\n            </table>\n        </div>\n    </fieldset>\n\n    </div>"
};

	return content[tabId] || '';
}

function endpointToMethod(endpoint) {
	var map = {
		'modem-status': 'modem_status',
		'modem_status': 'modem_status',
		'notif-list': 'notif_list',
		'notif_list': 'notif_list',
		'lock-status': 'lock_status',
		'lock_status': 'lock_status',
		'reboot-modem': 'reboot_modem',
		'reboot_modem': 'reboot_modem',
		'notif-clear': 'notif_clear',
		'notif_clear': 'notif_clear',
		'notif-process': 'notif_process',
		'notif_process': 'notif_process',
		'save-config': 'save_config',
		'save_config': 'save_config',
		'telegram-config': 'telegram_config',
		'telegram_config': 'telegram_config',
		'telegram-status': 'telegram_status',
		'telegram_status': 'telegram_status',
		'save-telegram-config': 'save_telegram_config',
		'save_telegram_config': 'save_telegram_config',
		'test-telegram': 'test_telegram',
		'test_telegram': 'test_telegram',
		'telegram-toggle': 'telegram_toggle',
		'telegram_toggle': 'telegram_toggle'
	};

	return map[endpoint] || endpoint;
}

function callApi(endpoint, params) {
	params = params || {};
	var paramNames = Object.keys(params);
	var call = rpc.declare({
		object: 'lpac_esim',
		method: endpointToMethod(endpoint),
		params: paramNames,
		expect: { '': {} }
	});

	return call.apply(null, paramNames.map(function(name) { return params[name]; })).catch(function(err) {
		return { success: false, error: err && err.message ? err.message : String(err) };
	});
}

// Dynamically load eSIM JS modules
function loadEsimModules() {
	// Compatibility: provide apiGet/apiPost that lpac-esim JS modules expect.
	// The legacy Lua CGI path is replaced by rpcd/ubus calls.
	window.apiGet = function(endpoint) {
		return callApi(endpoint, {});
	};

	window.apiPost = function(endpoint, params) {
		return callApi(endpoint, params || {});
	};

	// Provide showTab compatibility function
	window.showTab = showEsimTab;
	window.checkLockStatus = checkLockStatus;
	window.startLockPolling = startLockPolling;

	// Load each module in order, then initialize the active tab.
	var scripts = [
		'lpac-esim/js/jsQR.js',
		'lpac-esim/js/lpac-esim-info.js',
		'lpac-esim/js/lpac-esim-profiles.js',
		'lpac-esim/js/lpac-esim-download.js',
		'lpac-esim/js/lpac-esim-notifications.js',
		'lpac-esim/js/lpac-esim-config.js',
		'lpac-esim/js/lpac-esim-telegram.js'
	];

	loadScriptsSequentially(scripts, function() {
		loadEsimTab('info-tab');
		startDialStatePolling();
	});
}

var esimLockPollTimer = null;

function getLockStatusData(data) {
	if (data && data.payload && data.payload.data)
		return data.payload.data;

	if (data && data.data)
		return data.data;

	return data || {};
}

function setLockBanner(visible, text) {
	var banner = document.getElementById('esim-lock-banner');
	var bannerText = document.getElementById('esim-lock-text');

	if (banner)
		banner.style.display = visible ? 'block' : 'none';

	if (bannerText && text)
		bannerText.textContent = text;
}

function checkLockStatus(callback) {
	if (typeof window.apiGet !== 'function') return Promise.resolve(null);

	return window.apiGet('lock_status')
		.then(function(data) {
			var status = getLockStatusData(data);

			if (status && status.locked) {
				setLockBanner(true, _('Operation in progress... Please wait.'));
				return status;
			}

			setLockBanner(false);
			if (callback) callback(status && status.last_result ? status.last_result : null);
			return status;
		})
		.catch(function() {
			setLockBanner(false);
			return null;
		});
}

function startLockPolling(onUnlocked) {
	if (esimLockPollTimer)
		clearInterval(esimLockPollTimer);

	function pollLock() {
		if (typeof window.apiGet !== 'function') return;

		window.apiGet('lock_status')
			.then(function(data) {
				var status = getLockStatusData(data);

				if (status && status.locked) {
					setLockBanner(true, _('Operation in progress... Please wait.'));
					return;
				}

				setLockBanner(false);
				if (esimLockPollTimer) {
					clearInterval(esimLockPollTimer);
					esimLockPollTimer = null;
				}

				if (onUnlocked)
					onUnlocked(status && status.last_result ? status.last_result : null);
			})
			.catch(function() {
				setLockBanner(true, _('Connection lost — modem may be rebooting. Waiting for recovery...'));
			});
	}

	esimLockPollTimer = setInterval(pollLock, 5000);
	pollLock();
}

function checkConnectivity() {
	if (typeof window.apiGet !== 'function') return;
	var status = document.getElementById('esim-connectivity-status');

	if (status) {
		status.style.backgroundColor = '#999';
		status.title = _('Checking dial status...');
	}

	return window.apiGet('dial_state')
		.then(function(data) {
			var state = data && data.state ? data.state : 'unknown';
			var color = '#999';
			var title = _('Dial status unknown');

			if (state === 'connected') {
				color = '#00FF00';
				title = _('Dial connected');
			} else if (state === 'disconnected') {
				color = '#FF0000';
				title = _('Dial disconnected');
			} else if (state === 'recovering') {
				color = '#FFA500';
				title = _('Dial recovering');
			}

			if (data && data.message)
				title += ': ' + data.message;

			if (status) {
				status.style.backgroundColor = color;
				status.title = title;
			}
		})
		.catch(function() {
			if (status) {
				status.style.backgroundColor = '#FFA500';
				status.title = _('Dial status unavailable');
			}
		});
}

function startDialStatePolling() {
	checkConnectivity();
	poll.add(function() {
		if (document.hidden)
			return Promise.resolve();

		return checkConnectivity();
	}, DIAL_STATE_POLL_INTERVAL);
}
