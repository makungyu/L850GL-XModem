/* lpac-esim-telegram.js — v1.0.0 */
'use strict';

var telegramOriginalConfig = null;

// Auto-init when apiGet is already available (xmodem-next context where
// window.apiGet is set before scripts load). In legacy LuCI, apiGet is
// defined in lpac-esim-main.js which may load after this file, so the
// showTab() lazy-load mechanism calls loadTelegramConfig() explicitly.
if (typeof apiGet === 'function') {
    loadTelegramConfig();
    checkBotStatus();
}

function loadTelegramConfig() {
    apiGet('telegram_config')
        .then(function(data) {
            if (data && data.config) {
                var c = data.config;
                document.getElementById('tg-enabled').checked = (c.enabled === '1');
                document.getElementById('tg-token').value = c.token || '';
                document.getElementById('tg-chat-id').value = c.chat_id || '';
                document.getElementById('tg-poll-interval').value = c.poll_interval || '1';
                document.getElementById('tg-allow-disruptive').checked = (c.allow_disruptive !== '0');
                document.getElementById('tg-require-confirm').checked = (c.require_confirm !== '0');
                telegramOriginalConfig = getTelegramFormConfig();
            }
            document.getElementById('telegram-loading').style.display = 'none';
            document.getElementById('telegram-content').style.display = 'block';
            bindTelegramButtons();
        })
        .catch(function() {
            document.getElementById('telegram-loading').textContent = 'Failed to load config.';
        });
}

function bindTelegramButtons() {
    var botApplyBtn = document.getElementById('tg-apply-bot-btn');
    var securityApplyBtn = document.getElementById('tg-apply-security-btn');
    var testBtn = document.getElementById('tg-test-btn');

    if (botApplyBtn && !botApplyBtn.dataset.bound) {
        botApplyBtn.dataset.bound = '1';
        botApplyBtn.addEventListener('click', function(ev) {
            ev.preventDefault();
            applyTelegramBotSettings(botApplyBtn);
        });
    }

    if (securityApplyBtn && !securityApplyBtn.dataset.bound) {
        securityApplyBtn.dataset.bound = '1';
        securityApplyBtn.addEventListener('click', function(ev) {
            ev.preventDefault();
            applyTelegramSecuritySettings(securityApplyBtn);
        });
    }

    if (testBtn && !testBtn.dataset.bound) {
        testBtn.dataset.bound = '1';
        testBtn.addEventListener('click', function(ev) {
            ev.preventDefault();
            testTelegramBot(testBtn);
        });
    }
}

function checkBotStatus() {
    apiGet('telegram_status')
        .then(function(data) {
            var el = document.getElementById('tg-status-indicator');
            var lastPoll = document.getElementById('tg-last-poll');
            if (!el) return;

            if (data && data.running) {
                var stateText = data.state === 'ok' ? '● Running (connected)' :
                                data.state === 'error' ? '● Running (connection error)' :
                                '● Running';
                var stateColor = data.state === 'ok' ? '#28a745' :
                                 data.state === 'error' ? '#ffc107' : '#28a745';
                el.innerHTML = '<span style="color: ' + stateColor + ';">' + stateText + '</span>';
            } else {
                el.innerHTML = '<span style="color: #dc3545;">○ Stopped</span>';
            }

            if (lastPoll && data && data.last_poll) {
                var ago = Math.floor(Date.now() / 1000) - data.last_poll;
                lastPoll.textContent = ago < 5 ? 'just now' : ago + 's ago';
            } else if (lastPoll) {
                lastPoll.textContent = '-';
            }
        })
        .catch(function() {
            var el = document.getElementById('tg-status-indicator');
            if (el) el.textContent = '? Unknown';
        });
}

function getTelegramFormConfig() {
    var enabledEl = document.getElementById('tg-enabled');
    var tokenEl = document.getElementById('tg-token');
    var chatIdEl = document.getElementById('tg-chat-id');
    var pollIntervalEl = document.getElementById('tg-poll-interval');
    var allowDisruptiveEl = document.getElementById('tg-allow-disruptive');
    var requireConfirmEl = document.getElementById('tg-require-confirm');

    if (!enabledEl || !tokenEl || !chatIdEl || !pollIntervalEl || !allowDisruptiveEl || !requireConfirmEl)
        return null;

    return {
        enabled: enabledEl.checked ? '1' : '0',
        token: tokenEl.value.trim(),
        chat_id: chatIdEl.value.trim(),
        poll_interval: pollIntervalEl.value || '1',
        allow_disruptive: allowDisruptiveEl.checked ? '1' : '0',
        require_confirm: requireConfirmEl.checked ? '1' : '0'
    };
}

function showTelegramActionResult(anchorEl, ok, msg) {
    if (!anchorEl || !anchorEl.parentNode) return;

    var prev = anchorEl.parentNode.querySelector('.xmodem-action-result');
    if (prev) prev.parentNode.removeChild(prev);

    anchorEl.parentNode.appendChild(E('div', {
        'class': 'xmodem-action-result alert-message ' + (ok ? 'success' : 'danger'),
        'style': 'margin-top: 8px;'
    }, [ E('strong', {}, ok ? '✓ ' : '✗ '), msg ]));
}

function setTelegramButtonBusy(button, busy, text) {
    if (!button) return;

    if (busy) {
        button.dataset.originalText = button.textContent;
        button.disabled = true;
        button.classList.add('spinning');
        button.textContent = text || 'Applying...';
    } else {
        button.disabled = false;
        button.classList.remove('spinning');
        button.textContent = button.dataset.originalText || 'Apply';
    }
}

function notifyTelegramResult(ok, msg) {
    var luciUi = window.esimLuciUi;
    if (luciUi && luciUi.addNotification)
        luciUi.addNotification(null, E('p', {}, msg), ok ? 'success' : 'error');
}

function applyTelegramConfig(button, label) {
    var config = getTelegramFormConfig();
    if (!config) {
        showTelegramActionResult(button, false, 'Telegram form is not ready.');
        return;
    }

    if (config.enabled === '1' && !config.token) {
        showTelegramActionResult(button, false, 'Bot Token is required when bot is enabled.');
        return;
    }

    if (config.enabled === '1' && !config.chat_id) {
        showTelegramActionResult(button, false, 'Chat ID is required when bot is enabled.');
        return;
    }

    setTelegramButtonBusy(button, true, 'Applying...');

    apiPost('save_telegram_config', config)
        .then(function(data) {
            if (data && data.success) {
                telegramOriginalConfig = config;
                var msg = (label || 'Telegram configuration') + ' applied successfully. Bot service restarted.';
                showTelegramActionResult(button, true, msg);
                notifyTelegramResult(true, msg);
                setTimeout(checkBotStatus, 3000);
            } else {
                var failMsg = 'Failed to apply ' + (label || 'Telegram configuration').toLowerCase() + ': ' + (data && data.error ? data.error : 'Unknown error');
                showTelegramActionResult(button, false, failMsg);
                notifyTelegramResult(false, failMsg);
            }
        })
        .catch(function(e) {
            var errMsg = 'Error applying ' + (label || 'Telegram configuration').toLowerCase() + ': ' + (e && e.message ? e.message : 'Network error');
            showTelegramActionResult(button, false, errMsg);
            notifyTelegramResult(false, errMsg);
        })
        .then(function() {
            setTelegramButtonBusy(button, false);
        }, function(e) {
            setTelegramButtonBusy(button, false);
            throw e;
        });
}

function applyTelegramBotSettings(button) {
    applyTelegramConfig(button, 'Bot settings');
}

window.applyTelegramBotSettings = applyTelegramBotSettings;

function applyTelegramSecuritySettings(button) {
    applyTelegramConfig(button, 'Security settings');
}

window.applyTelegramSecuritySettings = applyTelegramSecuritySettings;

window.testTelegramBot = testTelegramBot;

function resetTelegramConfig() {
    if (!telegramOriginalConfig) return;
    var c = telegramOriginalConfig;
    document.getElementById('tg-enabled').checked = (c.enabled === '1');
    document.getElementById('tg-token').value = c.token || '';
    document.getElementById('tg-chat-id').value = c.chat_id || '';
    document.getElementById('tg-poll-interval').value = c.poll_interval || '1';
    document.getElementById('tg-allow-disruptive').checked = (c.allow_disruptive !== '0');
    document.getElementById('tg-require-confirm').checked = (c.require_confirm !== '0');
}

function testTelegramBot(button) {
    var token = document.getElementById('tg-token').value.trim();
    var chatId = document.getElementById('tg-chat-id').value.trim();

    if (!token || !chatId) {
        showTelegramActionResult(button, false, 'Please enter Bot Token and Chat ID first.');
        return;
    }

    setTelegramButtonBusy(button, true, 'Testing...');

    apiPost('test_telegram', { token: token, chat_id: chatId })
        .then(function(data) {
            if (data && data.success) {
                showTelegramActionResult(button, true, 'Test message sent successfully. Check your Telegram.');
                notifyTelegramResult(true, 'Test message sent successfully.');
            } else {
                var msg = 'Test failed: ' + (data.error || 'Unknown error');
                showTelegramActionResult(button, false, msg);
                notifyTelegramResult(false, msg);
            }
        })
        .catch(function() {
            showTelegramActionResult(button, false, 'Network error during test.');
            notifyTelegramResult(false, 'Network error during test.');
        })
        .then(function() {
            setTelegramButtonBusy(button, false);
        }, function(e) {
            setTelegramButtonBusy(button, false);
            throw e;
        });
}
