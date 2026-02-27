<?php
// ─────────────────────────────────────────────────────────────────────────────
// AgenDAV settings - mounted into the container at
// /var/www/agendav/web/config/settings.php
//
// Values are hardcoded (not getenv) because run.sh does literal sed
// substitution on this file using the env var names as tokens, which
// corrupts any PHP that contains those strings.
// ─────────────────────────────────────────────────────────────────────────────

// Site
$app['site.title'] = 'Calendar';
$app['site.footer'] = 'natecalvert.org';

// CalDAV server (internal Docker network)
$app['caldav.baseurl'] = 'http://radicale:5232';
$app['caldav.baseurl.public'] = 'https://radicale.natecalvert.org';
$app['caldav.authmethod'] = 'basic';

// Trusted proxies (cloudflared)
$app['proxies'] = ['172.16.0.0/12', '192.168.0.0/16', '10.0.0.0/8'];

// Database (stateless SQLite, ephemeral)
$app['db.options'] = [
    'path' => '/var/www/agendav/db/agendav.sqlite',
    'driver' => 'pdo_sqlite',
];

// Logging
$app['log.path'] = '/tmp/';

// ─────────────────────────────────────────────────────────────────────────────
// DEFAULT PREFERENCES
// These are applied to all users. Since preference saving is broken on this
// image (Doctrine/PHP version mismatch), these are the only way to configure
// the UI.
// ─────────────────────────────────────────────────────────────────────────────

// Language
$app['defaults.language'] = 'en';

// Timezone
$app['defaults.timezone'] = 'America/New_York';

// Date format: ymd, dmy, mdy
$app['defaults.date_format'] = 'mdy';

// Time format: '12' or '24'
$app['defaults.time_format'] = '12';

// First day of week: 0 = Sunday, 1 = Monday
$app['defaults.weekstart'] = 0;

// Show week numbers: true or false
$app['defaults.show_week_nb'] = false;

// Show current time marker: true or false
$app['defaults.show_now_indicator'] = true;

// Default view: month, week, day or list
$app['defaults.default_view'] = 'month';

// List view days
$app['defaults.list_days'] = 14;

// Calendar sharing (disabled, single user)
$app['calendar.sharing'] = false;

// Logout redirection
$app['logout.redirection'] = '';
