#!/bin/sh
set -e

# Symfony Container Automations
# https://serversideup.net/open-source/docker-php/docs/customizing-the-image/adding-your-own-start-up-scripts

CONSOLE="/var/www/html/bin/console"

# Check if we're in a Symfony project
if [ ! -f "$CONSOLE" ]; then
    echo "No Symfony project detected, skipping automations"
    exit 0
fi

echo "Starting Symfony automations..."

# Wait for database if Doctrine is installed (skip for SQLite)
if php "$CONSOLE" list doctrine 2>/dev/null | grep -q "doctrine:query:sql"; then
    if ! echo "${DATABASE_URL:-}" | grep -q "sqlite"; then
        echo "Waiting for database..."
        COUNTER=0
        MAX_TRIES=60
        while ! php "$CONSOLE" doctrine:query:sql "SELECT 1" --quiet 2>/dev/null; do
            COUNTER=$((COUNTER + 1))
            if [ $COUNTER -ge $MAX_TRIES ]; then
                echo "Database not available after ${MAX_TRIES}s, continuing anyway..."
                break
            fi
            sleep 1
        done
        if [ $COUNTER -lt $MAX_TRIES ]; then
            echo "Database is available"
        fi
    fi
fi

# Run database migrations (--allow-no-migration prevents error if no migrations)
echo "Running database migrations..."
if php "$CONSOLE" doctrine:migrations:migrate --no-interaction --allow-no-migration 2>&1; then
    echo "Migrations complete"
else
    echo "Migrations skipped (Doctrine may not be installed)"
fi

# Clear and warm up cache
echo "Rebuilding cache..."
php "$CONSOLE" cache:clear --no-warmup
php "$CONSOLE" cache:warmup
echo "Cache rebuilt"

echo "Symfony automations complete!"
