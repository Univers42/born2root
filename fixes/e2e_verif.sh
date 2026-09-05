#!/bin/bash

echo "=== 1. ROOT REDIRECT ===" && curl -sI http://127.0.0.1:8082/ | head -3
echo "=== 2. WORDPRESS FRONT PAGE ===" && curl -sL http://127.0.0.1:8082/wordpress/ | grep -o '<title>[^<]*</title>'
echo "=== 3. WP-LOGIN ===" && curl -sI http://127.0.0.1:8082/wordpress/wp-login.php | head -3
echo "=== 4. WP-ADMIN (redirect chain) ===" && curl -sIL --max-redirs 3 http://127.0.0.1:8082/wordpress/wp-admin/ 2>&1 | grep -E '^HTTP|^Location'
echo "=== 5. CSS SERVING ===" && curl -sI http://127.0.0.1:8082/wordpress/wp-includes/css/dist/block-library/style.min.css | head -3
echo "=== 6. JS SERVING ===" && curl -sI http://127.0.0.1:8082/wordpress/wp-includes/js/jquery/jquery.min.js | head -3
echo "=== 7. WP-JSON API ===" && curl -sI http://127.0.0.1:8082/wordpress/wp-json/ | head -3
echo "=== 8. TUTORIALS ===" && curl -sI http://127.0.0.1:8082/wordpress/?post_type=tutorial | head -3
echo "=== 9. DASHBOARD LOGIN TEST ===" && curl -sL -c /tmp/wp_test.txt -b /tmp/wp_test.txt \
    -d 'log=admin&pwd=admin123wp!&wp-submit=Log+In&redirect_to=%2Fwordpress%2Fwp-admin%2F&testcookie=1' \
    -H 'Cookie: wordpress_test_cookie=WP%20Cookie%20check' \
    'http://127.0.0.1:8082/wordpress/wp-login.php' 2>&1 | grep -o '<title>[^<]*</title>'
echo "=== 10. PLUGIN ACTIVE ===" && curl -sL -b /tmp/wp_test.txt 'http://127.0.0.1:8082/wordpress/wp-admin/plugins.php' | grep -o 'Tech Blog Toolkit' | head -1
echo "=== 11. DASHBOARD WIDGET ===" && curl -sL -b /tmp/wp_test.txt 'http://127.0.0.1:8082/wordpress/wp-admin/' | grep -oE '(Tech Blog Toolkit|Tutorials Published|Born2beRoot)' | sort -u

ssh -t b2b "sudo lighttpd -tt -f /etc/lighttpd/lighttpd.conf 2>&1; echo '=== PLUGINS ==='; sudo runuser -u www-data -- wp plugin list --path=/var/www/html/wordpress --format=table 2>&1; echo '=== PERMALINKS ==='; sudo runuser -u www-data -- wp option get permalink_structure --path=/var/www/html/wordpress 2>&1"
