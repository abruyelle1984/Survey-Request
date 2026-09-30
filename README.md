# Survey Requests : mise en service

Application web installable (PWA) de gestion des demandes d'implantation. L'interface est en anglais pour les utilisateurs US. Les comptes, la base de données et la mise à jour en direct passent par **Supabase** (offre gratuite suffisante), et l'hébergement par **GitHub Pages**.

## Contenu

| Fichier | Rôle |
|---|---|
| `index.html` | L'application (tu y colles tes clés Supabase) |
| `supabase/schema.sql` | Tables, rôles, règles de sécurité et workflow |
| `manifest.webmanifest`, `sw.js`, `icon*` | Installation sur téléphone et PC |

## Rôles

| Rôle | Peut faire |
|---|---|
| **Requester** (Production, méthodes…) | Créer une demande, compléter si info manquante, annuler la sienne, signer la réception, signaler un problème |
| **Surveyor** | Tout voir, accepter, demander un complément, rejeter, planifier, clôturer, faire signer sur son appareil, saisir une demande pour quelqu'un (demande orale) |
| **Admin** (toi) | Tout ce qui précède, plus la gestion des utilisateurs (rôles, activation) |

Les règles sont appliquées **côté serveur** : un utilisateur ne peut ni modifier directement les tables ni sauter une étape du workflow. Chaque action est horodatée et nominative dans l'historique.

## Installation (environ 30 minutes)

### 1. Supabase
1. Crée un compte sur supabase.com, puis un projet (région **East US** conseillée).
2. **SQL Editor › New query** : colle tout `supabase/schema.sql`, puis **Run**.
3. **Authentication › Sign In / Providers** : désactive **Allow new users to sign up**. Seules les personnes que tu invites pourront entrer.
4. **Project Settings › API** : copie la **Project URL** et la clé **anon public**.

### 2. Configurer l'app
Dans `index.html`, en haut du fichier, remplis `APP_CONFIG` :
```js
SUPABASE_URL: "https://xxxx.supabase.co",
SUPABASE_ANON_KEY: "eyJ...",
PROJECT_NAME: "Potomac River Tunnel S1405"
```
La clé *anon* peut être publique : la sécurité repose sur les règles du fichier SQL.

### 3. GitHub Pages
1. Crée un dépôt GitHub et dépose tous les fichiers à la racine (le dossier `supabase/` peut rester, il ne contient pas de secret).
2. **Settings › Pages** : Source *Deploy from a branch*, branche `main`, dossier `/root`.
3. Note l'URL, du type `https://ton-compte.github.io/survey-requests/`.
4. Retour dans Supabase, **Authentication › URL Configuration** : mets cette URL dans **Site URL** et dans **Redirect URLs**.

### 4. Ton compte admin
1. Supabase, **Authentication › Users › Invite user** : ton email.
2. Clique le lien reçu : l'app te demande ton nom et un mot de passe.
3. SQL Editor :
```sql
update public.profiles set role = 'admin'
 where id = (select id from auth.users where email = 'ton.email@exemple.com');
```
4. Recharge l'app : l'onglet **Users** apparaît.

### 5. Ajouter les utilisateurs
- Invite chaque personne depuis **Authentication › Users › Invite user**. Elle arrive comme *Requester*.
- Dans l'onglet **Users** de l'app, passe tes géomètres en *Surveyor*.
- Pour retirer quelqu'un, décoche **Active** : son historique reste intact.

L'envoi d'emails intégré à Supabase est limité à quelques emails par heure. Pour inviter beaucoup de monde d'un coup, deux solutions : configurer un SMTP (**Project Settings › Authentication › SMTP**), ou créer les comptes avec **Add user › Create new user** (cocher *Auto confirm*) et transmettre le mot de passe provisoire.

### 6. Installer sur les postes
- **PC (Chrome/Edge)** : icône « Installer » dans la barre d'adresse.
- **iPhone** : Safari › Partager › *Sur l'écran d'accueil*.
- **Android** : Chrome › menu › *Installer l'application*.

## À savoir
- **Projet gratuit Supabase** : il se met en pause après 7 jours sans aucune activité. Avec un usage quotidien, ce n'est pas un problème. Le plan Pro (25 $/mois) supprime cette limite et ajoute des sauvegardes quotidiennes.
- **Export** : l'onglet Dashboard exporte toutes les demandes en CSV, et chaque demande a son PV en PDF avec la signature et l'historique.
- **Données** : elles sont hébergées chez Supabase, pas sur les serveurs Bouygues. Fais valider l'usage par l'IT du projet si les demandes contiennent des informations sensibles.
