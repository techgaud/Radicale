<?php
// ─────────────────────────────────────────────────────────────────────────────
// AgenDAV settings - mounted into the container at
// /var/www/agendav/web/config/settings.php
//
// All values that the Docker image normally sets via env vars are included
// here so this file is the single source of truth.
// ─────────────────────────────────────────────────────────────────────────────

// Site
$app['site.title'] = getenv('AGENDAV_TITLE') ?: 'Calendar';
$app['site.footer'] = getenv('AGENDAV_FOOTER') ?: '';

// CalDAV server (internal Docker network)
$app['caldav.baseurl'] = getenv('AGENDAV_CALDAV_SERVER') ?: 'http://radicale:5232';
$app['caldav.baseurl.public'] = getenv('AGENDAV_CALDAV_PUBLIC_URL') ?: $app['caldav.baseurl'];
$app['caldav.authmethod'] = 'basic';

// Trusted proxies (cloudflared)
$app['proxies'] = ['172.16.0.0/12', '192.168.0.0/16', '10.0.0.0/8'];

// Database (stateless SQLite, ephemeral)
$app['db.options'] = [
    'path' => '/tmp/agendav.sqlite',
    'driver' => 'pdo_sqlite',
];

// Logging
$app['log.path'] = getenv('AGENDAV_LOG_DIR') ?: '/tmp/';

// ─────────────────────────────────────────────────────────────────────────────
// DEFAULT PREFERENCES
// These are applied to all users. Since preference saving is broken on this
// image (Doctrine/PHP version mismatch), these are the only way to configure
// the UI.
// ─────────────────────────────────────────────────────────────────────────────

// Language
$app['defaults.language'] = getenv('AGENDAV_LANG') ?: 'en';

// Timezone
$app['defaults.timezone'] = getenv('AGENDAV_TIMEZONE') ?: 'America/New_York';

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

// Default view: month, agendaWeek, agendaDay
$app['defaults.default_calendar_view'] = 'month';

// List view days
$app['defaults.list_days'] = 14;

// Calendar sharing (disabled, single user)
$app['calendar.sharing'] = false;

// Logout redirection
$app['logout.redirection'] = '';
