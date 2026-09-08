#!/usr/bin/env hellish

# Create backup directory if it doesn't exist
BACKUP_DIR=~/backups
mkdir -p $BACKUP_DIR

# Set source directory and create timestamp

TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
BACKUP_FILE="$BACKUP_DIR/notion_wordpress_sync_$TIMESTAMP.tar.gz"

# Create the backup
echo "Creating backup of Notion WP Sync plugin..."
if tar -czf "$BACKUP_FILE" -C /var/www/html/wp-content/plugins/ notion_wordpress_sync/; then
    echo "Backup created successfully: $BACKUP_FILE"
    echo "Backup size: $(du -h "$BACKUP_FILE" | cut -f1)"
else
    echo "Backup failed!"
fi
