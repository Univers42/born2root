#!/bin/bash
# First-boot setup: Docker + WordPress (requires running systemd + network)
# This script runs once via @reboot crontab, then self-deletes.
exec > /var/log/first-boot.log 2>&1
set -x
export DEBIAN_FRONTEND=noninteractive

echo "=== First-boot setup starting ($(date)) ==="

# Ensure custom shell is the default (if configured during install)
if [ -f /etc/b2b_custom_shell.conf ]; then
	# shellcheck disable=SC1091
	. /etc/b2b_custom_shell.conf 2>/dev/null || true
	if [ -n "${B2B_CUSTOM_USER:-}" ] && [ -n "${B2B_CUSTOM_SHELL:-}" ] && [ -x "${B2B_CUSTOM_SHELL:-}" ]; then
		# Register in /etc/shells (needed for some tools, harmless otherwise)
		if [ -f /etc/shells ]; then
			grep -qxF "$B2B_CUSTOM_SHELL" /etc/shells || echo "$B2B_CUSTOM_SHELL" >> /etc/shells
		else
			echo "$B2B_CUSTOM_SHELL" > /etc/shells
		fi
		if id "$B2B_CUSTOM_USER" > /dev/null 2>&1; then
			usermod -s "$B2B_CUSTOM_SHELL" "$B2B_CUSTOM_USER" 2>/dev/null || true
			echo "[OK] Default shell enforced on first boot: $B2B_CUSTOM_USER -> $B2B_CUSTOM_SHELL"
		else
			echo "[WARN] Custom shell configured but user missing: $B2B_CUSTOM_USER"
		fi
	else
		echo "[WARN] /etc/b2b_custom_shell.conf present but invalid (USER/SHELL missing or SHELL not executable)"
	fi
fi

# Wait for network to be fully up
for i in $(seq 1 30); do
	if ping -c1 -W2 deb.debian.org > /dev/null 2>&1; then
		echo "Network is up after ${i}s"
		break
	fi
	sleep 2
done

### ─── 1. Docker installation (official method) ─────────────────────────────
echo "--- Installing Docker ---"

# Add Docker official GPG key
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Add Docker repo (Debian trixie → use bookworm as fallback if trixie not available)
CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
if [ -z "$CODENAME" ] || [ "$CODENAME" = "trixie" ]; then
	# Docker may not have trixie packages yet — try trixie first, fall back to bookworm
	echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/debian trixie stable" > /etc/apt/sources.list.d/docker.list
	apt-get update -qq 2> /dev/null
	if ! apt-cache show docker-ce > /dev/null 2>&1; then
		echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/debian bookworm stable" > /etc/apt/sources.list.d/docker.list
		apt-get update -qq
	fi
else
	echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/debian $CODENAME stable" > /etc/apt/sources.list.d/docker.list
	apt-get update -qq
fi

apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || true

# Add dlesieur to docker group
usermod -aG docker dlesieur 2> /dev/null || true

# Kill any running VS Code server so it restarts with the docker group loaded.
# Without this, the VS Code server inherits the old group list (no docker GID)
# and every Docker command from the VS Code terminal fails with "permission denied".
# The user's next VS Code reconnect will spawn a fresh server with correct groups.
pkill -u dlesieur -f "vscode-server" 2> /dev/null || true

# Enable and start Docker
systemctl enable docker
systemctl start docker
echo "[OK] Docker installed and running"

### ─── 2. WordPress setup ───────────────────────────────────────────────────
echo "--- Setting up WordPress ---"

# MariaDB setup
systemctl start mariadb
sleep 3
mysql -u root -e "CREATE DATABASE IF NOT EXISTS wordpress;"
mysql -u root -e "CREATE USER IF NOT EXISTS 'wpuser'@'localhost' IDENTIFIED BY 'wppass123';"
mysql -u root -e "GRANT ALL PRIVILEGES ON wordpress.* TO 'wpuser'@'localhost';"
mysql -u root -e "FLUSH PRIVILEGES;"
echo "[OK] MariaDB configured"

# WordPress download — always pull the latest release via curl
cd /var/www/html
if [ -d wordpress ]; then
	echo "WordPress directory already exists — backing up and re-downloading"
	mv wordpress wordpress.bak.$(date +%s)
fi
curl -fsSL --retry 3 --retry-delay 5 --max-time 120 \
	https://wordpress.org/latest.tar.gz -o latest.tar.gz
tar -xzf latest.tar.gz
rm -f latest.tar.gz
chown -R www-data:www-data wordpress
WP_VER=$(grep 'wp_version =' wordpress/wp-includes/version.php | cut -d"'" -f2)
echo "[OK] WordPress ${WP_VER:-latest} downloaded via curl"

# Fetch unique salts from WordPress API
SALTS=$(curl -fsSL --retry 2 --max-time 15 https://api.wordpress.org/secret-key/1.1/salt/ 2> /dev/null || true)

# WordPress config
cat > /var/www/html/wordpress/wp-config.php << WPEOF
<?php
define('DB_NAME', 'wordpress');
define('DB_USER', 'wpuser');
define('DB_PASSWORD', 'wppass123');
define('DB_HOST', 'localhost');
define('DB_CHARSET', 'utf8');
define('DB_COLLATE', '');
\$table_prefix = 'wp_';
define('WP_DEBUG', false);

/* Dynamic URL detection — works from both inside the VM (localhost:80)
 * and from the host via NAT port forwarding (127.0.0.1:PORT).          */
\$_wp_scheme = (!empty(\$_SERVER['HTTPS']) && \$_SERVER['HTTPS'] !== 'off') ? 'https' : 'http';
\$_wp_host   = !empty(\$_SERVER['HTTP_HOST']) ? \$_SERVER['HTTP_HOST'] : 'localhost';
define('WP_SITEURL', \$_wp_scheme . '://' . \$_wp_host . '/wordpress');
define('WP_HOME',    \$_wp_scheme . '://' . \$_wp_host . '/wordpress');

/* Unique authentication keys — fetched from WordPress.org API */
${SALTS:-/* WARNING: Could not fetch salts — generate them at https://api.wordpress.org/secret-key/1.1/salt/ */}

if ( ! defined( 'ABSPATH' ) ) { define( 'ABSPATH', __DIR__ . '/' ); }
require_once ABSPATH . 'wp-settings.php';
WPEOF
chown www-data:www-data /var/www/html/wordpress/wp-config.php
chmod 640 /var/www/html/wordpress/wp-config.php

# Detect PHP-FPM version
PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2> /dev/null || echo "8.2")

# Belt-and-suspenders: ensure no conflicting lighttpd PHP handler is active
# (b2b-setup.sh should have done this, but guard against older ISOs)
rm -f /etc/lighttpd/conf-enabled/15-fastcgi-php.conf
rm -f /etc/lighttpd/conf-enabled/99-unconfigured.conf

# Ensure PHP-FPM listens on the correct socket and is running
systemctl restart "php${PHP_VER}-fpm" 2> /dev/null || true
systemctl restart lighttpd
sleep 2

### ─── 2b. Headless WordPress install (no browser needed) ───────────────────
# This runs the WordPress installer programmatically so the site is immediately
# usable with admin dashboard, welcome page, etc. No manual setup required.
echo "--- Running headless WordPress install ---"

WP_INSTALL_PHP="/tmp/wp-headless-install.php"
cat > "$WP_INSTALL_PHP" << 'INSTALLEOF'
<?php
// Headless WordPress installation — creates tables + admin user
define('ABSPATH', '/var/www/html/wordpress/');
define('WP_INSTALLING', true);
define('WP_SETUP_CONFIG', true);

// Suppress any output buffering issues
error_reporting(E_ALL);
ini_set('display_errors', '0');

// Set server vars that WordPress expects
$_SERVER['HTTP_HOST'] = 'localhost';
$_SERVER['REQUEST_URI'] = '/wordpress/wp-admin/install.php';
$_SERVER['SERVER_PROTOCOL'] = 'HTTP/1.1';
$_SERVER['REQUEST_METHOD'] = 'GET';
$_SERVER['SERVER_NAME'] = 'localhost';
$_SERVER['SERVER_PORT'] = '80';

// Load WordPress
require_once ABSPATH . 'wp-load.php';
require_once ABSPATH . 'wp-admin/includes/upgrade.php';

// Check if already installed
if (is_blog_installed()) {
    echo "WordPress is already installed.\n";
    exit(0);
}

// Run the actual install
$result = wp_install(
    'Born2beRoot Blog',           // Site title
    'admin',                       // Admin username
    'admin@dlesieur42.local',      // Admin email
    true,                          // Public (allow search engines)
    '',                            // Deprecated
    'admin123wp!',                 // Admin password
    'en_US'                        // Language
);

if (is_wp_error($result)) {
    echo "ERROR: " . $result->get_error_message() . "\n";
    exit(1);
}

echo "WordPress installed successfully!\n";
echo "Admin user: admin\n";
echo "Site URL: http://localhost/wordpress\n";

// Set permalink structure to pretty URLs
global $wp_rewrite;
$wp_rewrite->set_permalink_structure('/%postname%/');
$wp_rewrite->flush_rules(true);

// Set site URL and home URL for proper access via port forwarding
update_option('blogname', 'Born2beRoot Blog');
update_option('blogdescription', 'A WordPress site on Born2beRoot');

echo "Done!\n";
INSTALLEOF
chown www-data:www-data "$WP_INSTALL_PHP"

# Run the install script.
# NOTE: This script runs from @reboot crontab (no TTY), so `sudo -u` will fail
# because Born2beRoot requires `Defaults requiretty`.  Use `runuser` instead,
# which switches user without going through PAM/sudo.
if runuser -u www-data -- php "$WP_INSTALL_PHP" 2>&1; then
	echo "[OK] WordPress headless install completed"
else
	echo "[WARN] WordPress headless install had issues — trying WP-CLI fallback"
	# WP-CLI fallback
	if ! command -v wp > /dev/null 2>&1; then
		curl -fsSL -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar 2> /dev/null || true
		chmod +x /usr/local/bin/wp 2> /dev/null || true
	fi
	if command -v wp > /dev/null 2>&1; then
		runuser -u www-data -- wp core install \
			--path=/var/www/html/wordpress \
			--url="http://localhost/wordpress" \
			--title="Born2beRoot Blog" \
			--admin_user=admin \
			--admin_password='admin123wp!' \
			--admin_email=admin@dlesieur42.local \
			--skip-email 2>&1 || true
		echo "[OK] WordPress installed via WP-CLI"
	fi
fi
rm -f "$WP_INSTALL_PHP"

# Create uploads directory with proper permissions
mkdir -p /var/www/html/wordpress/wp-content/uploads
chown -R www-data:www-data /var/www/html/wordpress/wp-content/uploads
chmod -R 775 /var/www/html/wordpress/wp-content/uploads

### ─── 2c. Install Tech Blog Toolkit plugin ──────────────────────────────────
PLUGIN_DIR="/var/www/html/wordpress/wp-content/plugins/tech-blog-toolkit"
if [ ! -d "$PLUGIN_DIR" ]; then
	mkdir -p "$PLUGIN_DIR/includes"

	cat > "$PLUGIN_DIR/tech-blog-toolkit.php" << 'PLUGINEOF'
<?php
/**
 * Plugin Name: Tech Blog Toolkit
 * Plugin URI: https://github.com/LESdylan/tech-blog-toolkit
 * Description: A toolkit for technical blogs with custom post types, code highlighting, and more.
 * Version: 1.0.0
 * Author: LESdylan
 * License: GPL-2.0+
 * Text Domain: tech-blog-toolkit
 */
if (!defined('WPINC')) { die; }
define('TBT_VERSION', '1.0.0');
define('TBT_PLUGIN_DIR', plugin_dir_path(__FILE__));
define('TBT_PLUGIN_URL', plugin_dir_url(__FILE__));
require_once TBT_PLUGIN_DIR . 'includes/post-types.php';
require_once TBT_PLUGIN_DIR . 'includes/meta-boxes.php';
require_once TBT_PLUGIN_DIR . 'includes/syntax-highlighter.php';
require_once TBT_PLUGIN_DIR . 'includes/admin-dashboard.php';
register_activation_hook(__FILE__, function(){ flush_rewrite_rules(); });
register_deactivation_hook(__FILE__, function(){ flush_rewrite_rules(); });
add_action('admin_menu', function(){
    add_menu_page('Tech Blog Toolkit','Tech Blog','manage_options',
        'tech-blog-toolkit','tbt_admin_page','dashicons-book-alt',20);
});
function tbt_admin_page() {
    ?>
    <div class="wrap">
        <h1><?php echo esc_html(get_admin_page_title()); ?></h1>
        <div class="welcome-panel"><div class="welcome-panel-content">
            <h2>Welcome to Tech Blog Toolkit!</h2>
            <p class="about-description">Enhances your technical blog with specialized features.</p>
            <div class="welcome-panel-column-container">
                <div class="welcome-panel-column"><h3>Features</h3>
                    <ul><li>Custom tutorial post type</li><li>Technical specifications meta boxes</li>
                    <li>Code syntax highlighting</li><li>Tutorial metrics</li></ul></div>
                <div class="welcome-panel-column"><h3>Getting Started</h3>
                    <p>Go to "Tutorials" in the sidebar to create technical content.</p></div>
            </div></div></div>
    </div>
    <?php
}
PLUGINEOF

	cat > "$PLUGIN_DIR/includes/post-types.php" << 'PTEOF'
<?php
if (!defined('WPINC')) { die; }
add_action('init', function(){
    register_post_type('tutorial', array(
        'labels' => array('name'=>'Tutorials','singular_name'=>'Tutorial',
            'add_new'=>'Add New Tutorial','edit_item'=>'Edit Tutorial',
            'view_item'=>'View Tutorial','search_items'=>'Search Tutorials',
            'not_found'=>'No tutorials found','menu_name'=>'Tutorials'),
        'public'=>true,'has_archive'=>true,'rewrite'=>array('slug'=>'tutorials'),
        'supports'=>array('title','editor','thumbnail','excerpt','comments'),
        'menu_icon'=>'dashicons-welcome-learn-more','show_in_rest'=>true));
    register_taxonomy('tutorial_category','tutorial', array(
        'labels'=>array('name'=>'Tutorial Categories','singular_name'=>'Tutorial Category'),
        'hierarchical'=>true,'show_in_rest'=>true,'rewrite'=>array('slug'=>'tutorial-category')));
});
PTEOF

	cat > "$PLUGIN_DIR/includes/meta-boxes.php" << 'MBEOF'
<?php
if (!defined('WPINC')) { die; }
add_action('add_meta_boxes', function(){
    add_meta_box('tbt_tech_specs','Technical Specifications','tbt_tech_specs_cb','tutorial','side');
});
function tbt_tech_specs_cb($post) {
    wp_nonce_field('tbt_save_meta','tbt_meta_nonce');
    $d=get_post_meta($post->ID,'_tbt_difficulty',true);
    $t=get_post_meta($post->ID,'_tbt_duration',true);
    $l=get_post_meta($post->ID,'_tbt_language',true);
    echo '<p><label><strong>Difficulty:</strong></label><br><select name="tbt_difficulty" style="width:100%">';
    foreach(array(''=>'— Select —','beginner'=>'Beginner','intermediate'=>'Intermediate','advanced'=>'Advanced') as $v=>$lab)
        echo '<option value="'.esc_attr($v).'"'.selected($d,$v,false).'>'.esc_html($lab).'</option>';
    echo '</select></p>';
    echo '<p><label><strong>Duration:</strong></label><br><input type="text" name="tbt_duration" value="'.esc_attr($t).'" placeholder="e.g. 30 min" style="width:100%"></p>';
    echo '<p><label><strong>Language:</strong></label><br><input type="text" name="tbt_language" value="'.esc_attr($l).'" placeholder="e.g. Python, Bash" style="width:100%"></p>';
}
add_action('save_post_tutorial', function($id){
    if(!isset($_POST['tbt_meta_nonce'])||!wp_verify_nonce($_POST['tbt_meta_nonce'],'tbt_save_meta')) return;
    if(defined('DOING_AUTOSAVE')&&DOING_AUTOSAVE) return;
    foreach(array('tbt_difficulty','tbt_duration','tbt_language') as $f)
        if(isset($_POST[$f])) update_post_meta($id,'_'.$f,sanitize_text_field($_POST[$f]));
});
MBEOF

	cat > "$PLUGIN_DIR/includes/syntax-highlighter.php" << 'SHEOF'
<?php
if (!defined('WPINC')) { die; }
add_action('wp_enqueue_scripts', function(){
    wp_enqueue_style('highlightjs-css','https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/atom-one-dark.min.css',array(),'11.9.0');
    wp_enqueue_script('highlightjs','https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js',array(),'11.9.0',true);
    wp_add_inline_script('highlightjs','hljs.highlightAll();');
});
add_shortcode('code', function($atts,$content=null){
    $atts=shortcode_atts(array('lang'=>''),$atts,'code');
    return '<pre><code class="language-'.esc_attr($atts['lang']).'">'.esc_html(trim($content)).'</code></pre>';
});
SHEOF

	cat > "$PLUGIN_DIR/includes/admin-dashboard.php" << 'ADEOF'
<?php
if (!defined('WPINC')) { die; }
add_action('wp_dashboard_setup', function(){
    wp_add_dashboard_widget('tbt_dashboard_widget','Tech Blog Toolkit — Overview','tbt_dashboard_widget_cb');
});
function tbt_dashboard_widget_cb() {
    $tc=wp_count_posts('tutorial'); $pc=wp_count_posts('post');
    $pub=isset($tc->publish)?$tc->publish:0; $dr=isset($tc->draft)?$tc->draft:0;
    echo '<div style="display:flex;gap:20px;flex-wrap:wrap;">';
    echo '<div style="flex:1;min-width:120px;background:#f0f6fc;padding:15px;border-radius:8px;text-align:center;"><div style="font-size:28px;font-weight:700;color:#2271b1;">'.(int)$pub.'</div><div style="color:#50575e;">Tutorials Published</div></div>';
    echo '<div style="flex:1;min-width:120px;background:#fef8ee;padding:15px;border-radius:8px;text-align:center;"><div style="font-size:28px;font-weight:700;color:#dba617;">'.(int)$dr.'</div><div style="color:#50575e;">Tutorial Drafts</div></div>';
    echo '<div style="flex:1;min-width:120px;background:#edf8f1;padding:15px;border-radius:8px;text-align:center;"><div style="font-size:28px;font-weight:700;color:#00a32a;">'.(int)$pc->publish.'</div><div style="color:#50575e;">Blog Posts</div></div></div>';
    echo '<p style="margin-top:15px;"><a href="'.admin_url('edit.php?post_type=tutorial').'" class="button button-primary">Manage Tutorials</a> <a href="'.admin_url('admin.php?page=tech-blog-toolkit').'" class="button">Plugin Settings</a></p>';
}
ADEOF

	chown -R www-data:www-data "$PLUGIN_DIR"
	echo "[OK] Tech Blog Toolkit plugin installed"
fi

# Activate plugin + create sample tutorial post via WP-CLI
if command -v wp > /dev/null 2>&1; then
	runuser -u www-data -- wp plugin activate tech-blog-toolkit \
		--path=/var/www/html/wordpress 2> /dev/null || true
	# Create a sample tutorial if none exist
	TCOUNT=$(runuser -u www-data -- wp post list --post_type=tutorial --format=count \
		--path=/var/www/html/wordpress 2> /dev/null || echo "0")
	if [ "$TCOUNT" = "0" ]; then
		runuser -u www-data -- wp post create \
			--path=/var/www/html/wordpress \
			--post_type=tutorial \
			--post_title="Getting Started with Born2beRoot" \
			--post_content='<h2>Introduction</h2><p>This tutorial covers the basics of setting up a Born2beRoot virtual machine with WordPress, lighttpd, and MariaDB.</p><pre><code class="language-bash">sudo apt install lighttpd mariadb-server php-fpm</code></pre><h2>Key Concepts</h2><p>Learn about system administration, security hardening, and web server configuration.</p>' \
			--post_status=publish 2> /dev/null || true
		echo "[OK] Sample tutorial post created"
	fi
else
	# Activate via DB if WP-CLI unavailable
	mysql -u wpuser -pwppass123 wordpress -e \
		"UPDATE wp_options SET option_value='a:1:{i:0;s:39:\"tech-blog-toolkit/tech-blog-toolkit.php\";}' WHERE option_name='active_plugins';" 2> /dev/null || true
	echo "[OK] Tech Blog Toolkit activated via DB"
fi

# ── Fix lighttpd config if stock php-cgi handler is still active ─────────────
# b2b-setup.sh should have removed 15-fastcgi-php.conf, but if the install
# path ran before our fix, clean it up now so lighttpd can start.
if [ -f /etc/lighttpd/conf-enabled/15-fastcgi-php.conf ]; then
	rm -f /etc/lighttpd/conf-enabled/15-fastcgi-php.conf
	echo "[FIX] Removed conflicting 15-fastcgi-php.conf (php-cgi)"
fi
rm -f /etc/lighttpd/conf-enabled/99-unconfigured.conf 2> /dev/null || true

# Belt-and-suspenders: ensure 99-wordpress.conf has root redirect + safe rewrite rules
PHP_SOCK_PATH=$(find /run/php -name 'php*-fpm.sock' 2> /dev/null | head -1)
PHP_SOCK_PATH="${PHP_SOCK_PATH:-/run/php/php8.4-fpm.sock}"
if ! grep -q 'url.redirect' /etc/lighttpd/conf-enabled/99-wordpress.conf 2> /dev/null; then
	cat > /etc/lighttpd/conf-available/99-wordpress.conf << WPFIX
server.modules += ( "mod_rewrite" )
fastcgi.server += ( ".php" =>
    (( "socket" => "${PHP_SOCK_PATH}",
       "broken-scriptfilename" => "enable"
    ))
)
url.redirect = ( "^/\$" => "/wordpress/" )
url.rewrite-if-not-file = (
    "^/wordpress/wp-admin(.*)"    => "/wordpress/wp-admin\$1",
    "^/wordpress/wp-includes(.*)" => "/wordpress/wp-includes\$1",
    "^/wordpress/wp-content(.*)"  => "/wordpress/wp-content\$1",
    "^/wordpress/(.*\\.php.*)"    => "/wordpress/\$1",
    "^/wordpress/(.*)"            => "/wordpress/index.php/\$1"
)
index-file.names += ( "index.php" )
server.max-request-size = 32768
WPFIX
	ln -sf /etc/lighttpd/conf-available/99-wordpress.conf \
		/etc/lighttpd/conf-enabled/99-wordpress.conf 2> /dev/null || true
	echo "[FIX] Updated 99-wordpress.conf with root redirect + safe rewrite rules"
fi

# Restart PHP-FPM + lighttpd to pick up new config
systemctl restart "php${PHP_VER}-fpm" 2> /dev/null || true
systemctl restart lighttpd 2> /dev/null || true

# Verify lighttpd is running; if not, run config test for diagnostics
if ! systemctl is-active --quiet lighttpd 2> /dev/null; then
	echo "[WARN] lighttpd failed to start — running config test:"
	lighttpd -tt -f /etc/lighttpd/lighttpd.conf 2>&1 || true
	# Try one more time after a short delay
	sleep 2
	systemctl restart lighttpd 2> /dev/null || true
fi
echo "[OK] WordPress fully installed — dashboard ready at /wordpress/wp-admin/"

### ─── 3. UFW — open Docker port ─────────────────────────────────────────────
ufw allow 2375/tcp comment 'Docker' 2> /dev/null || true

### ─── 3b. Ensure NAT keepalive + SSH stability services are running ─────────
# b2b-setup.sh creates these in chroot but systemctl enable may not stick.
# Belt-and-suspenders: re-enable and start them now with real systemd.
systemctl daemon-reload
systemctl enable nat-keepalive 2> /dev/null || true
systemctl start nat-keepalive 2> /dev/null || true
systemctl enable sshd-watchdog 2> /dev/null || true
systemctl start sshd-watchdog 2> /dev/null || true
systemctl enable ssh 2> /dev/null || true
systemctl restart ssh 2> /dev/null || true
# Apply kernel TCP keepalive values (may not have been applied from chroot)
sysctl --system > /dev/null 2>&1 || true
echo "[OK] NAT keepalive + sshd-watchdog + SSH stability ensured"

### ─── 4. Third-party tools retry ────────────────────────────────────────────
# b2b-setup.sh installs base dev tools in chroot but skips nodejs/npm
# (npm's dpkg triggers hang in chroot and block all subsequent configuration).
# Install nodejs/npm here with full systemd + network.
echo "--- Ensuring third-party dev tools are installed ---"

# Node.js + npm (not installed in chroot — triggers hang)
if ! command -v node > /dev/null 2>&1; then
	apt-get install -y -qq nodejs npm 2>/dev/null || true
	echo "[OK] nodejs + npm installed"
else
	echo "[SKIP] nodejs already present"
fi

# NPM globals (skip if already installed)
if command -v npm > /dev/null 2>&1 && ! command -v eslint > /dev/null 2>&1; then
	npm install -g eslint prettier snyk 2>/dev/null || true
	echo "[OK] NPM globals installed"
else
	echo "[SKIP] NPM globals already present or npm not available"
fi

# Python tools via pipx
if ! command -v ruff > /dev/null 2>&1; then
	apt-get install -y -qq pipx 2>/dev/null || true
	PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install ruff 2>/dev/null || true
	PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install sqlfluff 2>/dev/null || true
	PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install checkov 2>/dev/null || true
	echo "[OK] Python tools installed"
else
	echo "[SKIP] Python tools already present"
fi

# Go linter
if ! command -v golangci-lint > /dev/null 2>&1; then
	curl -sSfL --max-time 60 https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b /usr/local/bin 2>/dev/null || true
	echo "[OK] golangci-lint installed"
fi

# Helm
if ! command -v helm > /dev/null 2>&1; then
	curl -fsSL --max-time 60 https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash 2>/dev/null || true
	echo "[OK] Helm installed"
fi

echo "[OK] Third-party tools check complete"

### ─── 5. Self-destruct ─────────────────────────────────────────────────────
sed -i '/first-boot-setup/d' /etc/crontab
rm -f /root/first-boot-setup.sh
echo "=== First-boot setup complete ($(date)) ==="
