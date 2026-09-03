'use strict';
'require view';
'require uci';

// Embeds the ttyd instance that runs /usr/sbin/simei (section "simei" in /etc/config/ttyd).
return view.extend({
	load: function() {
		return uci.load('ttyd');
	},

	render: function() {
		var port = uci.get('ttyd', 'simei', 'port') || '7681';
		var ssl = uci.get('ttyd', 'simei', 'ssl') || '0';
		var proto = (ssl === '1') ? 'https:' : 'http:';
		var url = proto + '//' + window.location.hostname + ':' + port + '/';

		var nodes = [ E('h2', {}, _('SIM / IMEI (TUI)')) ];

		if (window.location.protocol === 'https:' && ssl !== '1') {
			nodes.push(E('p', { 'class': 'alert-message warning' },
				_('This page is served over HTTPS but the terminal runs on plain HTTP, so the browser will not embed it. Open it in a new tab: ') +
				'<a href="' + url + '" target="_blank">' + url + '</a>'));
		}

		nodes.push(E('iframe', {
			'src': url,
			'style': 'width: 100%; min-height: 640px; border: 1px solid #ccc; border-radius: 3px; resize: vertical;'
		}));
		nodes.push(E('p', { 'class': 'cbi-section-descr' },
			_('Same tool over ssh: ') + '<code>ssh root@' + window.location.hostname + ' simei</code>'));

		return E('div', { 'class': 'cbi-map' }, nodes);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
