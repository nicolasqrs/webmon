# WebMon

WebMon est une plateforme de supervision et de récupération automatique pour des conteneurs Docker.

Son objectif est de **découvrir des conteneurs existants sans les interrompre**, de vérifier qu'ils fonctionnent réellement, de conserver les informations nécessaires à leur reconstruction et, lorsqu'une politique l'autorise, de tenter automatiquement une récupération.

WebMon ne se contente donc pas de vérifier qu'un conteneur est `running`.

Il cherche à répondre à une question plus utile :

> **Le service rendu par ce conteneur fonctionne-t-il réellement ?**

---

## 1. Fonctionnement général

WebMon fonctionne selon la logique suivante :

```text
Conteneur Docker
      |
      v
Découverte automatique
      |
      v
Capture de sa configuration
      |
      v
Ajout à l'inventaire des conteneurs connus
      |
      v
Détermination du meilleur contrôle fonctionnel
      |
      v
Surveillance continue
      |
      +------------------------------+
      |                              |
      v                              v
Service OK                       Service KO
      |                              |
      v                              v
Continuer                    Échecs consécutifs
la surveillance                    |
                                   v
                           Panne confirmée
                                   |
                                   v
                         Politique de récupération
                                   |
              +--------------------+--------------------+
              |                    |                    |
              v                    v                    v
        observe-only            restart            reconstruct
              |                    |                    |
              v                    v                    v
          Ne rien faire        Restart Docker       Restart Docker
                                                        |
                                                        v
                                                Toujours en panne ?
                                                        |
                                                 +------+------+
                                                 |             |
                                                 v             v
                                                non           oui
                                                 |             |
                                                 v             v
                                                OK      Reconstruction
```

La récupération est volontairement progressive :

1. WebMon détecte la panne.
2. Il attend plusieurs échecs consécutifs avant de la considérer comme réelle.
3. Il applique la politique du conteneur.
4. Si un redémarrage est autorisé, il tente d'abord un `docker restart`.
5. Si le conteneur reste défaillant et que la reconstruction est autorisée, WebMon recrée le conteneur depuis la configuration qu'il avait sauvegardée.
6. Les volumes existants sont réutilisés afin de conserver les données persistantes.
7. WebMon vérifie ensuite que le service est de nouveau fonctionnel.

---

## 2. Ce que WebMon surveille

WebMon combine plusieurs méthodes de contrôle.

### 2.1 État Docker

WebMon récupère directement l'état réel des conteneurs avec Docker :

```text
running
exited
restarting
created
...
```

Cela permet notamment de différencier :

```text
conteneur running + service KO
    -> functional_failure

conteneur arrêté
    -> container_stopped

conteneur complètement absent
    -> missing_container

conteneur en boucle de redémarrage
    -> crash_loop
```

### 2.2 Healthcheck Docker

Si le conteneur possède déjà un `HEALTHCHECK`, WebMon l'utilise en priorité.

Exemples :

```text
healthy
starting
unhealthy
```

WebMon n'a donc pas besoin de remplacer un contrôle fonctionnel déjà défini correctement dans l'image ou dans Docker Compose.

### 2.3 Contrôle fonctionnel personnalisé

WebMon peut utiliser un contrôle spécifique lorsqu'un simple test HTTP n'est pas suffisant.

Dans l'environnement de démonstration, `worker-a` et `worker-b` écrivent un heartbeat dans :

```text
/data/heartbeat
```

WebMon vérifie l'âge de ce heartbeat.

Cela permet de détecter un cas comme :

```text
Docker : running
Processus : bloqué
Heartbeat : ancien
Résultat WebMon : CRITICAL
```

Autrement dit, un conteneur peut être démarré au sens Docker tout en étant inutilisable.

### 2.4 Détection HTTP automatique

Lorsqu'il n'existe ni contrôle personnalisé ni healthcheck Docker, WebMon tente automatiquement de trouver un service HTTP.

Il teste plusieurs ports Web courants, notamment :

```text
80
3000
3001
3100
5000
8000
8080
8096
8888
9000
9080
9090
9100
9187
```

et plusieurs chemins classiques :

```text
/
/health
/healthz
/ready
/metrics
```

Un code HTTP `2xx` ou `3xx` est actuellement considéré comme fonctionnel.

Lorsqu'un endpoint valide est trouvé, WebMon le mémorise dans :

```text
runtime/http-checks.tsv
```

Les contrôles suivants utilisent directement cet endpoint.

#### Modes HTTP

WebMon possède trois moyens d'atteindre un service.

**`host`** : utilisé lorsqu'un port Docker est publié sur l'hôte. Exemple : `8081 -> 80/tcp`.

**`internal`** : utilisé lorsque WebMon partage déjà un réseau Docker avec le service. Exemple : `http://webmon-backend:3001/health`.

**`probe`** : pour un conteneur présent sur un réseau isolé, WebMon utilise le conteneur technique `webmon-probe`. Le probe est connecté temporairement au réseau concerné, effectue le contrôle, puis est déconnecté.

---

## 3. Ordre de priorité des contrôles

WebMon choisit le contrôle fonctionnel dans cet ordre :

```text
1. contrôle WebMon personnalisé
2. HEALTHCHECK Docker
3. contrôle HTTP automatique
4. aucun contrôle disponible
```

Un conteneur sans contrôle reconnu reste visible, mais peut être marqué comme non configuré.

---

## 4. Confirmation des pannes

WebMon ne déclenche pas une récupération après un seul échec.

Par défaut, la panne doit être observée plusieurs fois consécutivement :

```text
échec 1 -> suspect
échec 2 -> suspect
échec 3 -> panne confirmée
```

Le moteur conserve notamment :

```text
status
failure_type
consecutive_failures
failure_confirmed
recovery_mode
recovery_decision
```

Les informations sont écrites dans :

```text
runtime/failure-state.json
```

Exemple :

```json
{
  "name": "worker-a",
  "docker_state": "running",
  "status": "critical",
  "failure_type": "functional_failure",
  "consecutive_failures": 4,
  "failure_confirmed": true,
  "recovery_mode": "reconstruct",
  "recovery_decision": "restart_candidate"
}
```

---

## 5. Découverte et sauvegarde automatique de la configuration

Lorsqu'un nouveau conteneur est découvert, WebMon capture automatiquement sa configuration.

Les manifestes sont stockés dans :

```text
recovery/captured/
```

La capture peut contenir notamment :

```text
nom du conteneur
image Docker
commande
entrypoint
variables d'environnement
user
working directory
restart policy
volumes
bind mounts
réseaux
ports publiés
healthcheck
labels
```

### Sécurité

Les variables d'environnement peuvent contenir des mots de passe, tokens, clés API ou secrets applicatifs. Les manifestes sont donc créés avec des permissions restrictives et le répertoire est exclu de Git.

Ne publiez pas le contenu de `recovery/captured/` sur un dépôt public.

---

## 6. Inventaire des conteneurs attendus

Après capture, WebMon ajoute automatiquement le conteneur à son inventaire persistant :

```text
recovery/expected-containers.json
```

Cet inventaire permet de détecter un conteneur qui a totalement disparu.

```text
conteneur découvert
    ->
manifest capturé
    ->
conteneur ajouté à expected-containers.json
    ->
conteneur supprimé
    ->
WebMon sait qu'il devrait encore exister
    ->
missing_container
```

L'inventaire est différent de la politique de récupération :

```text
expected-containers.json
    = "ce conteneur est connu"

recovery-policies.json
    = "qu'est-ce que WebMon a le droit de faire ?"
```

---

## 7. Politiques de récupération

La configuration se trouve dans :

```text
config/recovery-policies.json
```

La configuration recommandée par défaut est :

```json
{
  "default": {
    "mode": "observe-only"
  },
  "containers": {}
}
```

Cela signifie que tous les nouveaux conteneurs sont automatiquement surveillés, mais que WebMon ne les modifie pas.

### `observe-only`

```json
{
  "mode": "observe-only"
}
```

WebMon détecte, surveille et confirme les pannes, mais n'effectue aucune action.

### `restart`

```json
{
  "mode": "restart"
}
```

Après confirmation d'une panne, WebMon peut exécuter :

```bash
docker restart <conteneur>
```

Si le conteneur a complètement disparu, WebMon ne le reconstruira pas.

### `reconstruct`

```json
{
  "mode": "reconstruct"
}
```

C'est le mode de récupération complet :

```text
panne confirmée
    |
    v
docker restart
    |
    v
nouveaux contrôles
    |
    +--> OK -> fin de l'incident
    |
    v
toujours KO
    |
    v
validation du manifeste
    |
    v
suppression du conteneur défectueux
    |
    v
reconstruction
    |
    v
réutilisation volumes + réseaux + ports + configuration
    |
    v
nouveau contrôle
```

Si le conteneur a complètement disparu, WebMon peut passer directement à la reconstruction après confirmation de la panne.

---

## 8. Mode maintenance

Un conteneur peut être temporairement protégé contre les actions automatiques.

```json
{
  "default": {
    "mode": "observe-only"
  },
  "containers": {
    "mon-service": {
      "mode": "reconstruct",
      "maintenance": true
    }
  }
}
```

Lorsque `maintenance` vaut `true`, WebMon continue à observer le service mais n'exécute pas de récupération automatique.

C'est utile avant une maintenance applicative, un arrêt volontaire, une migration, un changement de configuration ou un dépannage manuel.

---

## 9. Reconstruction

Avant toute reconstruction, WebMon effectue un contrôle du manifeste.

Il vérifie notamment : JSON valide, nom du conteneur, image, restart policy, volumes, bind mounts, réseaux, présence locale de l'image et cohérence de la configuration supportée.

Le script principal est :

```text
scripts/reconstruct-container.sh
```

Il recrée notamment :

```text
--name
--restart
--user
--workdir
--entrypoint
--env
--label
--mount
--publish
--network
image
commande
```

Les volumes nommés existants ne sont pas supprimés. Cela permet à une application reconstruite de récupérer ses anciennes données.

---

## 10. Protection contre les boucles de récupération

WebMon conserve l'état de chaque incident dans :

```text
runtime/recovery-action-state.json
```

Il mémorise notamment :

```text
restart_attempted
reconstruction_attempted
restart_failure_count
incident_active
last_action
last_result
```

Pour un même incident, WebMon limite actuellement la récupération à un restart et une reconstruction. Cela évite une boucle infinie de récupération.

Lorsqu'un service revient à l'état sain, l'incident est clôturé et les compteurs d'action sont remis à zéro.

---

# 11. API WebMon

Le backend WebMon est un service Node.js nommé :

```text
webmon-backend
```

Il écoute sur le port interne `3001`.

Le backend n'accède pas directement au socket Docker. Cette séparation est volontaire :

```text
Docker socket
     |
     v
webmon-monitor
     |
     v
fichiers JSON dans /runtime
     |
     v
webmon-backend
     |
     v
API HTTP
     |
     v
frontend
```

Le composant disposant des privilèges Docker est donc principalement le monitor. Le backend lit les fichiers produits par le moteur de supervision et expose leur contenu via HTTP.

## `GET /api/containers`

Route principale utilisée pour afficher les conteneurs découverts.

```bash
curl http://localhost/api/containers
```

Le backend agrège notamment les informations provenant de :

```text
runtime/containers.json
runtime/functional.json
runtime/http-functional.json
```

Il associe à chaque conteneur son état Docker et le meilleur contrôle fonctionnel disponible.

Les conteneurs techniques portant le label :

```text
webmon.internal=true
```

sont filtrés de la liste destinée à l'utilisateur, notamment `webmon-monitor` et `webmon-probe`.

## `GET /api/tasks`

Cette route appartient à la partie historique de l'application WebMon et reste disponible pour la gestion des tâches de démonstration.

```bash
curl http://localhost/api/tasks
```

## `/health`

Le backend expose également un endpoint de santé utilisé par la supervision :

```text
/health
```

Depuis le réseau Docker, WebMon peut par exemple tester :

```text
http://webmon-backend:3001/health
```

---

## 12. Frontend

Le frontend WebMon affiche l'état des conteneurs et leurs contrôles fonctionnels.

Le chemin utilisateur est :

```text
Navigateur
   |
   v
webmon-nginx :80
   |
   +--> frontend
   |
   +--> /api/ -> backend
```

Nginx sert donc de point d'entrée principal. Le frontend actualise régulièrement les informations afin que les changements d'état apparaissent sans rechargement manuel permanent.

---

## 13. Stack WebMon

La stack comprend notamment :

```text
webmon-nginx
webmon-frontend
webmon-backend
webmon-postgres

webmon-prometheus
webmon-grafana
webmon-loki
webmon-promtail
webmon-cadvisor
webmon-node-exporter
webmon-postgres-exporter

webmon-monitor
webmon-probe
```

Les composants `monitor` et `probe` sont des composants internes de WebMon.

---

## 14. Ports principaux

| Service | Port |
|---|---:|
| WebMon / Nginx | `80` |
| Grafana | `3000` |
| Loki | `3100` |
| cAdvisor | `8080` |
| Prometheus | `9090` |
| Node Exporter | `9100` |
| PostgreSQL Exporter | `9187` |

PostgreSQL et le backend peuvent rester accessibles uniquement à l'intérieur du réseau Docker selon la configuration.

---

# 15. Installation

## Prérequis

Machine Linux avec :

```text
Docker Engine
Docker Compose plugin
Git
```

Outils pratiques pour l'administration locale :

```text
jq
curl
```

## Récupérer le projet

```bash
git clone https://github.com/HironixNervoxX/webmon.git
cd webmon
```

## Démarrer WebMon

```bash
docker compose up -d --build
```

Vérifier :

```bash
docker compose ps
```

Le point d'entrée principal est ensuite :

```text
http://IP_DU_SERVEUR/
```

ou localement :

```text
http://localhost/
```

---

# 16. Guide d'utilisation

## 16.1 Démarrer WebMon

```bash
cd ~/webmon
docker compose up -d
```

## 16.2 Arrêter WebMon

```bash
docker compose down
```

Ne pas utiliser `-v` sauf si vous souhaitez réellement supprimer les volumes Compose.

## 16.3 Voir l'état de la stack

```bash
docker compose ps
```

## 16.4 Voir les logs du moteur WebMon

```bash
docker logs -f webmon-monitor
```

Exemples de messages :

```text
WebMon recovery: restart de worker-a...
WebMon recovery: restart exécuté pour worker-a.

WebMon recovery: escalade vers reconstruction de worker-a...
WebMon reconstruct: création de worker-a...
WebMon reconstruct: démarrage de worker-a...
WebMon recovery: reconstruction après restart exécutée pour worker-a.
```

## 16.5 Voir les conteneurs découverts

```bash
jq . runtime/containers.json
```

## 16.6 Voir les contrôles HTTP appris

```bash
cat runtime/http-checks.tsv
```

## 16.7 Voir le résultat des contrôles HTTP

```bash
jq . runtime/http-functional.json
```

## 16.8 Voir l'état des pannes

```bash
jq . runtime/failure-state.json
```

Vue condensée :

```bash
jq -r '
  .[] |
  "\(.name) : \(.status) / \(.failure_type) / recovery=\(.recovery_mode)"
' runtime/failure-state.json
```

## 16.9 Voir l'historique des actions de récupération

```bash
jq . runtime/recovery-action-state.json
```

## 16.10 Voir les conteneurs attendus

```bash
jq . recovery/expected-containers.json
```

## 16.11 Autoriser uniquement un restart

Éditer `config/recovery-policies.json` :

```json
{
  "default": {
    "mode": "observe-only"
  },
  "containers": {
    "mon-service": {
      "mode": "restart",
      "maintenance": false
    }
  }
}
```

## 16.12 Autoriser la reconstruction complète

```json
{
  "default": {
    "mode": "observe-only"
  },
  "containers": {
    "mon-service": {
      "mode": "reconstruct",
      "maintenance": false
    }
  }
}
```

Une fois le fichier sauvegardé, WebMon relit automatiquement la politique.

## 16.13 Mettre un service en maintenance

Passer :

```json
"maintenance": true
```

Après l'intervention, remettre :

```json
"maintenance": false
```

## 16.14 Forcer manuellement une capture

La capture est normalement automatique.

```bash
./scripts/capture-recovery-manifest.sh mon-service
```

Le résultat sera placé dans :

```text
recovery/captured/mon-service.json
```

## 16.15 Vérifier un manifeste

```bash
./scripts/validate-recovery-manifest.sh \
  recovery/captured/mon-service.json
```

## 16.16 Voir une reconstruction sans l'exécuter

```bash
./scripts/render-recovery-dry-run.sh \
  recovery/captured/mon-service.json
```

Cette commande affiche le plan de reconstruction sans modifier Docker.

---

# 17. Ajouter un nouveau conteneur

Dans le cas général, aucune intégration spéciale n'est nécessaire pour la découverte.

Exemple :

```bash
docker run -d \
  --name mon-site \
  --restart unless-stopped \
  -p 8085:80 \
  nginx
```

WebMon va ensuite automatiquement :

```text
1. découvrir mon-site
2. enregistrer sa configuration
3. l'ajouter à l'inventaire attendu
4. rechercher un contrôle fonctionnel
5. commencer sa surveillance
```

Par sécurité, il héritera de `observe-only`. Il ne sera donc pas redémarré ou reconstruit automatiquement tant qu'une politique explicite ne l'autorise pas.

---

# 18. Exemple complet

Supposons le conteneur `site-apache` avec :

```text
image : httpd:2.4-alpine
port : 8081 -> 80/tcp
restart : unless-stopped
```

WebMon découvre automatiquement :

```text
http://host.docker.internal:8081/
```

et reçoit `HTTP 200`. Le service est donc marqué `OK`.

Si le réseau du conteneur est cassé :

```text
Docker state : running
HTTP : inaccessible
```

WebMon obtient `functional_failure`. Après plusieurs contrôles, `failure_confirmed` passe à `true`.

Si la politique est `observe-only`, aucune action n'est effectuée. Si elle est `restart`, WebMon peut redémarrer le conteneur. Si elle est `reconstruct`, WebMon peut escalader vers une reconstruction si le restart ne rétablit pas le service.

---

# 19. Test de reconstruction validé

Le mécanisme a notamment été testé avec `worker-a`.

Avant reconstruction :

```text
counter = 4681
```

Le conteneur a été volontairement rendu défectueux en supprimant `/bin/date` dans sa couche writable.

Le scénario observé a été :

```text
functional_failure
    ->
restart automatique
    ->
toujours CRITICAL
    ->
attente de nouveaux contrôles
    ->
reconstruction automatique
    ->
nouveau container ID
    ->
/bin/date restauré
    ->
ancien volume remonté
    ->
counter = 4709
    ->
status = OK
```

Cela confirme que la reconstruction remplace la couche du conteneur tout en conservant les données stockées dans le volume.

---

# 20. Fichiers importants

```text
config/
└── recovery-policies.json
    Politique de récupération.

runtime/
├── containers.json
├── functional.json
├── http-checks.tsv
├── http-functional.json
├── failure-counters.json
├── failure-state.json
└── recovery-action-state.json
    Etat runtime de WebMon.

recovery/
├── captured/
│   └── <container>.json
│       Manifestes de reconstruction.
│
└── expected-containers.json
    Inventaire persistant des conteneurs connus.

scripts/
├── discover-containers.sh
├── check-workers.sh
├── check-http-auto.sh
├── auto-capture-containers.sh
├── capture-recovery-manifest.sh
├── sync-expected-containers.sh
├── evaluate-failures.sh
├── execute-recovery-actions.sh
├── validate-recovery-manifest.sh
├── reconstruct-container.sh
└── render-recovery-dry-run.sh
```

---

# 21. Sécurité

Le conteneur `webmon-monitor` possède accès au socket Docker. Cela lui donne des privilèges très élevés sur l'hôte Docker.

L'accès au socket est nécessaire au fonctionnement actuel pour :

```text
inspecter les conteneurs
lire leur configuration
connecter le probe aux réseaux
redémarrer des conteneurs autorisés
reconstruire des conteneurs autorisés
```

Recommandations :

```text
laisser la politique par défaut en observe-only
n'autoriser restart/reconstruct que sur les services voulus
utiliser maintenance=true avant une intervention volontaire
ne jamais publier recovery/captured sur Git
limiter l'accès au serveur WebMon
sauvegarder séparément les volumes réellement importants
```

WebMon est un mécanisme de récupération de conteneurs, pas un remplacement d'une stratégie de sauvegarde des données.

---

# 22. Limites actuelles

La détection HTTP automatique est une détection générique. Un `HTTP 200` prouve qu'un endpoint répond, mais ne garantit pas forcément que toute la logique métier d'une application fonctionne.

Pour les services critiques, il est préférable de fournir un `HEALTHCHECK` Docker pertinent ou un contrôle WebMon personnalisé.

La reconstruction automatique dépend également de ce que le format de manifeste sait capturer et restituer. Avant d'utiliser `reconstruct` sur un service de production complexe, vérifier son manifeste :

```bash
./scripts/validate-recovery-manifest.sh \
  recovery/captured/<service>.json
```

et examiner éventuellement le dry-run :

```bash
./scripts/render-recovery-dry-run.sh \
  recovery/captured/<service>.json
```

---

# 23. Résumé

WebMon fournit aujourd'hui la chaîne suivante :

```text
Découverte automatique
        +
Capture automatique
        +
Inventaire persistant
        +
Contrôle fonctionnel
        +
Confirmation des pannes
        +
Politique par conteneur
        +
Restart automatique
        +
Escalade contrôlée
        +
Reconstruction automatique
        +
Conservation des volumes
        +
Retour automatique à l'état sain
```

Avec une philosophie simple :

> **Observer automatiquement, agir uniquement lorsqu'une politique l'autorise, et toujours tenter la récupération la moins destructive avant de reconstruire.**
