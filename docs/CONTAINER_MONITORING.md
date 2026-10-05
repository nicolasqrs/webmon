# Dashboard WebMon - Conteneurs

Accès : `http://IP_DU_SERVEUR:3000/d/webmon-containers/webmon-conteneurs`.
Ou Grafana > Dashboards > WebMon > WebMon - Conteneurs.

## Mise en place

Après récupération de la branche `fix/demo-deployment` :

```bash
docker compose -f docker-compose.yml -f docker-compose.demo.yml up -d --no-deps --force-recreate webmon-monitor
docker compose -f docker-compose.yml -f docker-compose.demo.yml restart grafana
```

Le monitor doit être recréé pour monter le nouveau script d'export.
Attendre la fin d'un cycle de supervision, puis la collecte Prometheus (15 secondes).
Grafana provisionne le nouveau dashboard ; le redémarrage assure aussi le chargement
du fichier si le répertoire était monté avant la mise à jour.

La collecte passe par le textfile collector de Node Exporter déjà présent.
Le nouveau fichier `node-exporter-textfile/containers.prom` ne contient que les noms,
états et résultats de contrôle. Les variables d'environnement des applications ne sont pas exportées.
L'ancien dashboard cAdvisor reste disponible.

## Ce qui est affiché

- Inventaire des conteneurs suivis, nombre démarré, sondes OK et pannes confirmées.
- Nombre de conteneurs sans sonde applicative et âge du dernier cycle.
- Tableau par conteneur : état Docker, type de sonde, résultat, mode de récupération.
- CPU, mémoire utilisée, réseau reçu et envoyé, filtrables par conteneur.

Le filtre Conteneur est alimenté par les métriques courantes de découverte.
Le mode Tous inclut les nouveaux conteneurs sans configuration de dashboard individuelle.
Les conteneurs internes portant `webmon.internal=true` sont exclus de cette vue.
Les conteneurs attendus disparus restent visibles dans le tableau, mais n'ont plus
de courbes de ressources actuelles. Un inventaire conservé volontairement ne disparaît
pas tant que son manifeste de récupération existe.

## Sondes et découverte automatique

Pour un nouveau conteneur du même hôte Docker, WebMon découvre son état et capture sa
configuration, puis utilise la première méthode disponible dans cet ordre :

1. Heartbeat d'un worker explicitement configuré.
2. Healthcheck Docker existant.
3. Sonde HTTP découverte automatiquement sur les ports et chemins connus.
4. État Docker seul : le résultat applicatif est Non testé.

Un nouveau service web standard ou un conteneur doté d'un healthcheck est donc
surveillé sans ajouter de panneau Grafana. Un service non HTTP (base, file de messages,
worker) doit disposer d'un healthcheck pertinent ou d'un heartbeat configuré.
Les chemins HTTP détectés sont `/`, `/health`, `/healthz`, `/ready`, `/metrics`.
Un port atypique, une authentification HTTP ou un service HTTPS seul peut nécessiter
un healthcheck explicite. La découverte n'est pas un scan de tous les protocoles.

La supervision automatique ne donne pas une autorisation automatique de récupération :
les politiques existantes continuent de s'appliquer, avec `observe-only` par défaut.

## Interpréter les résultats

- Démarré : le processus Docker tourne, sans garantie applicative.
- OK : la sonde retenue réussit. HTTP 2xx/3xx ne prouve pas toute la logique métier.
- KO : la sonde échoue ou le conteneur est arrêté/absent.
- Non testé : aucune sonde applicative adaptée n'a été trouvée.
- Démarrage : healthcheck Docker encore dans sa phase de démarrage.
- Âge du dernier cycle : si ce nombre augmente fortement, les états peuvent être périmés.

Le CPU est exprimé en pourcentage d'un cœur : 100 % représente un cœur occupé ;
une application utilisant plusieurs cœurs peut dépasser 100 %. La mémoire est en octets
avec conversion automatique par Grafana. Les débits réseau sont en octets/seconde.
Les courbes CPU/réseau nécessitent plusieurs échantillons après création d'un conteneur.

## Vérifier la collecte

```bash
docker logs --tail 50 webmon-monitor
curl -fsS http://localhost:9100/metrics | grep '^webmon_container_'
```

Dans Prometheus, vérifier les cibles `node-exporter` et `cadvisor`, puis exécuter :

```promql
webmon_container_functional
```

Si les états apparaissent mais pas les ressources, examiner :

```promql
container_memory_working_set_bytes{job="cadvisor",name!=""}
```

Les panneaux de ressources utilisent le label `name` des métriques Docker cAdvisor.
Si ce label n'est pas fourni par l'hôte, il faudra adapter cette collecte ; le tableau
des sondes WebMon reste indépendant de ces courbes.
