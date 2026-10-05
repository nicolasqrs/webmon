# Supervision des sites HTTP et HTTPS

WebMon peut surveiller une URL accessible depuis son conteneur monitor, même si le
site est hébergé sans Docker ou sur une autre machine. Cette supervision est en
lecture seule et n'effectue aucune récupération distante.

## Déployer

```bash
git switch main
git pull --ff-only https://github.com/nicolasqrs/webmon.git main
docker compose -f docker-compose.yml -f docker-compose.demo.yml up -d --build --no-deps webmon-monitor
docker compose -f docker-compose.yml -f docker-compose.demo.yml restart grafana
```

Le rebuild installe curl et les certificats CA. Les nouveaux montages nécessitent
la recréation du monitor, effectuée par `up`. Pour une installation sans le worker
de démonstration, retirer `-f docker-compose.demo.yml`.

Ouvrir `http://IP_DU_SERVEUR:3000/d/webmon-websites/webmon-sites-web` ou
Grafana > Dashboards > WebMon > WebMon - Sites web.

## Ajouter les sites

Éditer `config/websites.json`. Le fichier initial est vide : aucun site externe
n'est interrogé tant que vous n'avez pas renseigné vos URL. Exemple :

```json
[
  {
    "name": "Site vitrine",
    "url": "https://www.mon-site.fr/",
    "expected_status": 200,
    "timeout_seconds": 5,
    "failure_threshold": 3
  },
  {
    "name": "Intranet",
    "url": "http://192.168.1.50/health",
    "expected_status": 200,
    "timeout_seconds": 5,
    "failure_threshold": 3
  }
]
```

Remplacer les exemples par vos adresses. Les noms doivent être uniques.
Les valeurs par défaut sont 200, 5 secondes et 3 échecs. Un nouveau site est ajouté
au dashboard sans créer de panneau individuel. La configuration est relue à chaque
cycle, sans redémarrage. Supprimer une entrée retire ses métriques courantes ; son
historique reste dans Prometheus pendant la durée de rétention.

`localhost` désigne le conteneur monitor. Pour un site sur la machine Docker,
utiliser `http://host.docker.internal:PORT/`, si le service écoute sur une interface
accessible depuis Docker. Un service lié uniquement à 127.0.0.1 n'est pas joignable
par cette adresse. Les autres machines utilisent leur IP ou leur nom DNS.

## Contrôles et résultats

- Requête GET HTTP(S) ; jusqu'à 5 redirections HTTP(S) sont suivies.
- OK si curl termine sans erreur et si le code final correspond au code attendu.
- Timeout, erreur DNS, erreur TLS et code inattendu donnent KO.
- Le certificat HTTPS est vérifié avec les CA du monitor. Un certificat privé
  non approuvé produit KO ; aucune vérification TLS n'est désactivée.
- KO apparaît dès le premier échec ; la panne est confirmée après le seuil
  d'échecs consécutifs. Un contrôle réussi remet le compteur à zéro.
- La durée affichée inclut les redirections et les tentatives échouées.

La boucle des sites est indépendante de celle des conteneurs. Elle attend
30 secondes après la fin des contrôles. Les sites sont testés successivement :
avec beaucoup d'URL lentes, le cycle prend plus de temps. Trois échecs ne
correspondent donc pas exactement à 90 secondes.

Le dashboard présente les sites suivis, les sites OK, les pannes confirmées,
l'âge du dernier cycle, les codes HTTP et les temps de réponse. La disponibilité
sur la période est le pourcentage de contrôles OK enregistrés ; une interruption
de collecte n'est pas comptabilisée comme une panne du site.

Aucune alerte email ou notification n'est configurée par cette modification.
Le contrôle de contenu, l'alerte d'expiration de certificat et les ressources du
serveur distant restent hors de cette première version.

## Dépannage

```bash
docker logs --tail 50 webmon-monitor
docker exec webmon-monitor cat /runtime/websites.json
curl -fsS http://localhost:9100/metrics | grep '^webmon_website'
```

Le fichier d'état contient le code HTTP, le code d'erreur curl, le compteur
et la date de chaque contrôle. Les URL restent dans ce fichier local et ne sont
pas exportées comme labels Prometheus. Éviter de mettre des secrets dans les URL
ou de coller le fichier d'état sans vérifier son contenu.

Une configuration invalide conserve les derniers résultats. Si l'âge du dernier
cycle augmente, consulter les logs et corriger le JSON avant d'interpréter les
anciens états. Les panneaux utilisent la source Prometheus existante et les
métriques collectées via le textfile collector de Node Exporter.
