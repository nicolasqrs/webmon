# Déploiement et démonstration

Cette procédure vise un serveur Linux avec Docker Engine et le plugin Docker Compose,
sur un réseau privé. Prévoir les ports 80, 3000, 3100, 8080, 9090, 9100 et 9187 libres.
Les identifiants de démonstration restent ceux du projet ; ne pas exposer la stack à Internet.

## Démarrer

Depuis le dossier du dépôt :

```bash
docker compose -f docker-compose.yml -f docker-compose.demo.yml config -q
docker compose -f docker-compose.yml -f docker-compose.demo.yml up -d --build
docker compose -f docker-compose.yml -f docker-compose.demo.yml ps
docker logs --tail 50 webmon-monitor
```

L'interface est sur `http://IP_DU_SERVEUR/`, Grafana sur le port 3000.
Le premier cycle peut prendre plusieurs minutes pendant la découverte HTTP.
La pause de dix secondes entre les cycles ne garantit pas un contrôle toutes les dix secondes.

La configuration de démonstration ajoute uniquement `webmon-demo-worker`, son volume
de compteur et sa politique `reconstruct`. Tous les autres conteneurs restent en `observe-only`.
Le démarrage normal avec uniquement `docker-compose.yml` ne surveille aucun worker par
heartbeat par défaut. Pour un worker existant : `WEBMON_WORKERS='worker-a:15' docker compose up -d`.

## Vérifier le scénario complet

Installer `curl` et `jq` sur l'hôte si nécessaire, puis :

```bash
bash scripts/test-demo.sh
```

Ce test attend que le worker soit sain et capturé, supprime `/bin/date` uniquement dans
ce worker de démonstration, puis vérifie sa reconstruction, son retour à l'état sain,
son alias réseau et la conservation du compteur dans son volume. Le worker reste
présent après le test. Le test peut durer plusieurs minutes.

Pour suivre la démonstration dans un second terminal :

```bash
docker logs -f webmon-monitor
```

On doit voir un restart, puis une reconstruction si le heartbeat reste périmé.
En cas d'échec, conserver les logs et consulter `runtime/failure-state.json` et
`runtime/recovery-action-state.json`. Ne pas répéter une action manuelle sur un service réel.

## Montrer un conteneur disparu sans récupération

Après le test réussi, activer la maintenance pour le worker dans
`config/recovery-policies.demo.json` (`"maintenance": true`). Pour que le conteneur monitor
relise une éventuelle sauvegarde atomique de ce fichier, le recréer :

```bash
docker compose -f docker-compose.yml -f docker-compose.demo.yml up -d --force-recreate webmon-monitor
docker rm -f webmon-demo-worker
```

Au prochain cycle, le worker doit apparaître comme absent dans le dashboard.
Remettre ensuite `maintenance` à `false` et recréer le monitor avec la même commande :
WebMon pourra reconstruire le worker depuis son manifeste. Attendre son retour à OK.

## Arrêter

```bash
docker compose -f docker-compose.yml -f docker-compose.demo.yml down
```

Cette commande conserve les volumes. `make clean` et `down -v` les suppriment.

## Validation disponible sans Docker

```bash
node --test tests/*.test.js
python3 -m unittest discover -s tests -p 'test_*.py' -v
```

Ces tests exécutent les scripts contre un Docker simulé ; ils ne remplacent pas
`test-demo.sh` sur la machine de déploiement. La reconstruction reste destinée ici
à des conteneurs simples avec volumes/binds et réseaux bridge. Les devices, options
de sécurité et limites de ressources personnalisées ne sont pas restitués.
