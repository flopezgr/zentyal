# Copyright (C) 2012-2013 Zentyal S.L.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License, version 2, as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

use strict;
use warnings;

# Class: EBox::Samba::User
#
#   Samba user, stored in samba LDAP
#
package EBox::Samba::User;

use base 'EBox::Samba::OrganizationalPerson';

use EBox::Global;
use EBox::Gettext;

use EBox::Exceptions::External;
use EBox::Exceptions::UnwillingToPerform;

use EBox::Samba::Credentials;

use EBox::UsersAndGroups::User;

use Perl6::Junction qw(any);
use Encode;
use Net::LDAP::Control;
use Date::Calc;
use Error qw(:try);

use constant MAXPWDLENGTH   => 512;

# Method: changePassword
#
#   Configure a new password for the user
#
sub changePassword
{
    my ($self, $passwd, $lazy) = @_;

    $self->_checkPwdLength($passwd);

    $passwd = encode('UTF16-LE', "\"$passwd\"");

    # The password will be changed on save
    $self->set('unicodePwd', $passwd, 1);
    $self->save() unless $lazy;
}

# Method: setCredentials
#
#   Configure user credentials directly from kerberos hashes
#
# Parameters:
#
#   keys - array ref of krb5keys
#
sub setCredentials
{
    my ($self, $keys, $lazy) = @_;

    my $pwdSet = 0;
    my $credentials = new EBox::Samba::Credentials(krb5Keys => $keys);
    if ($credentials->supplementalCredentials()) {
        $self->set('supplementalCredentials', $credentials->supplementalCredentials(), 1);
        $pwdSet = 1;
    }
    if ($credentials->unicodePwd()) {
        $self->set('unicodePwd', $credentials->unicodePwd(), 1);
        $pwdSet = 1;
    }

    if ($pwdSet) {
        # This value is stored as a large integer that represents
        # the number of 100 nanosecond intervals since January 1, 1601 (UTC)
        my ($sec, $min, $hour, $day, $mon, $year) = gmtime(time);
        $year = $year + 1900;
        $mon += 1;
        my $days = Date::Calc::Delta_Days(1601, 1, 1, $year, $mon, $day);
        my $secs = $sec + $min * 60 + $hour * 3600 + $days * 86400;
        my $val = $secs * 10000000;
        $self->set('pwdLastSet', $val, 1);
    }

    my $bypassControl = Net::LDAP::Control->new(
        type => '1.3.6.1.4.1.7165.4.3.12',
        critical => 1 );
    $self->save($bypassControl) unless $lazy;
}

# Method: deleteObject
#
#   Delete the user
#
sub deleteObject
{
    my ($self) = @_;

    if ($self->checkObjectErasability()) {
        throw EBox::Exceptions::UnwillingToPerform(
            reason => __x('The object {x} is a system critical object.',
                          x => $self->dn()));
    }

    # Remove the roaming profile directory
    my $samAccountName = $self->get('samAccountName');
    my $path = EBox::Samba::PROFILES_DIR() . "/$samAccountName";
    EBox::Sudo::silentRoot("rm -rf '$path'");

    # TODO Remove this user from shares ACLs

    # Call super implementation
    shift @_;
    $self->SUPER::deleteObject(@_);
}

sub setupUidMapping
{
    my ($self, $uidNumber) = @_;

    # NOTE Samba4 beta2 support rfc2307, reading uidNumber from ldap instead idmap.ldb, but
    # it is not working when the user init session as DOMAIN/user but user@domain.com
    # FIXME Remove this when fixed
    my $type = $self->_ldap->idmap->TYPE_UID();
    $self->_ldap->idmap->setupNameMapping($self->sid(), $type, $uidNumber);
}

# Method: setAccountEnabled
#
#   Enables or disables the user account, setting the userAccountControl
#   attribute. For a description of this attribute check:
#   http://support.microsoft.com/kb/305144
#
sub setAccountEnabled
{
    my ($self, $enable, $lazy) = @_;

    my $flags = $self->get('userAccountControl');
    if ($enable) {
        $flags = $flags & ~0x0002;
    } else {
        $flags = $flags | 0x0002;
    }
    $self->set('userAccountControl', $flags, 1);

    $self->save() unless $lazy;
}

# Method: isAccountEnabled
#
#   Check if the account is enabled, reading the userAccountControl
#   attribute. For a description of this attribute check:
#   http://support.microsoft.com/kb/305144
#
# Returns:
#
#   boolean - 1 if enabled, 0 if disabled
#
sub isAccountEnabled
{
    my ($self) = @_;

    return not ($self->get('userAccountControl') & 0x0002);
}

# Method: addSpn
#
#   Add a service principal name to this account
#
sub addSpn
{
    my ($self, $spn, $lazy) = @_;

    my @spns = $self->get('servicePrincipalName');

    # return if spn already present
    foreach my $s (@spns) {
        return if (lc ($s) eq lc ($spn));
    }
    push (@spns, $spn);

    $self->set('servicePrincipalName', \@spns, $lazy);
}

sub createRoamingProfileDirectory
{
    my ($self) = @_;

    my $samAccountName  = $self->get('samAccountName');
    my $userSID         = $self->sid();
    my $domainAdminsSID = $self->_ldap->domainSID() . '-512';
    my $domainUsersSID  = $self->_ldap->domainSID() . '-513';

    # Create the directory if it does not exist
    my $samba = EBox::Global->modInstance('samba');
    my $path  = EBox::Samba::PROFILES_DIR() . "/$samAccountName";
    my $group = EBox::UsersAndGroups::DEFAULTGROUP();

    my @cmds = ();
    # Create the directory if it does not exist
    push (@cmds, "mkdir -p \'$path\'") unless -d $path;

    # Set unix permissions on directory
    push (@cmds, "chown $samAccountName:$group \'$path\'");
    push (@cmds, "chmod 0700 \'$path\'");

    # Set native NT permissions on directory
    my @perms;
    push (@perms, 'u:root:rwx');
    push (@perms, 'g::---');
    push (@perms, "g:$group:---");
    push (@perms, "u:$samAccountName:rwx");
    push (@cmds, "setfacl -b \'$path\'");
    push (@cmds, 'setfacl -R -m ' . join(',', @perms) . " \'$path\'");
    push (@cmds, 'setfacl -R -m d:' . join(',d:', @perms) ." \'$path\'");
    EBox::Sudo::root(@cmds);
}

sub setRoamingProfile
{
    my ($self, $enable, $path, $lazy) = @_;

    my $userName = $self->get('samAccountName');
    if ($enable) {
        $self->createRoamingProfileDirectory();
        $path .= "\\$userName";
        $self->set('profilePath', $path);
    } else {
        $self->delete('profilePath');
    }
    $self->save() unless $lazy;
}

sub setHomeDrive
{
    my ($self, $drive, $path, $lazy) = @_;

    my $userName = $self->get('samAccountName');
    $path .= "\\$userName";
    $self->set('homeDrive', $drive);
    $self->set('homeDirectory', $path);
    $self->save() unless $lazy;
}

# Method: create
#
#   Adds a new user
#
# Parameters:
#
#   user - hash ref containing:
#       'samAccountName'
#
#   params hash ref (all optional):
#       objectClass - additional objectClass to add to the ones from User.
#       givenName
#       initials
#       sn
#       displayName
#       description
#       clearPassword - Clear text password
#       kerberosKeys - Set of kerberos keys
#       uidNumber - user UID numberer
#
# Returns:
#
#   Returns the new create user object
#
sub create
{
    my ($self, $samAccountName, $params) = @_;

    # Check the password length if specified
    my $clearPassword = $params->{'clearPassword'};
    if (defined $clearPassword) {
        $self->_checkPwdLength($clearPassword);
    }

    my $usersMod = EBox::Global->modInstance('users');
    my $realm = $usersMod->kerberosRealm();
    my $attr = [];
    my @objectClass = ('user', 'posixAccount');
    if (defined $params->{objectClass}) {
        foreach my $object (@{$params->{objectClass}}) {
            push (@objectClass, $object) unless ($object ~~ @objectClass);
        }
    }
    push ($attr, objectClass => \objectClass);
    push ($attr, givenName   => $params->{givenName}) if defined $params->{givenName};
    push ($attr, initials    => $params->{initials}) if defined $params->{initials};
    push ($attr, sn          => $params->{sn}) if defined $params->{sn};
    push ($attr, displayName => $params->{displayName}) if defined $params->{displayName};
    push ($attr, description => $params->{description}) if defined $params->{description};
    # User specific attributes.
    push ($attr, sAMAccountName    => "$samAccountName");
    push ($attr, userPrincipalName => "$samAccountName\@$realm");
    push ($attr, userAccountControl => '514');
    push ($attr, uidNumber         => $params->{uidNumber}) if defined $params->{uidNumber};

    $createdUser = $self->SUPER::create($samAccountName, $attr);

    # Setup the uid mapping
    $createdUser->setupUidMapping($params->{uidNumber}) if defined $params->{uidNumber};

    # Set the password
    if (defined $params->{clearPassword}) {
        $createdUser->changePassword($params->{clearPassword});
        $createdUser->setAccountEnabled(1);
    } elsif (defined $params->{kerberosKeys}) {
        $createdUser->setCredentials($params->{kerberosKeys});
        $createdUser->setAccountEnabled(1);
    }

    # Return the new created user
    return $createdUser;
}

sub _checkPwdLength
{
    my ($self, $pwd) = @_;

    if (length($pwd) > MAXPWDLENGTH) {
        throw EBox::Exceptions::External(
                __x("Password must not be longer than {maxPwdLength} characters",
                    maxPwdLength => MAXPWDLENGTH));
    }
}

sub addToZentyal
{
    my ($self) = @_;

    my $uid       = $self->get('samAccountName');
    my $fullname  = $self->get('name');
    my $givenName = $self->get('givenName');
    my $surName   = $self->get('sn');
    my $comment   = $self->get('description');
    my $uidNumber = $self->get('uidNumber');
    $givenName = '-' unless defined $givenName;
    $surName = '-' unless defined $surName;

    my $params = {
        user => $uid,
        fullname => $fullname,
        givenname => $givenName,
        surname => $surName,
        comment => $comment,
    };

    my $zentyalUser = undef;
    my %optParams;
    $optParams{ignoreMods} = ['samba'];
    EBox::info("Adding samba user '$uid' to Zentyal");

    if ($uidNumber) {
        $optParams{uidNumber} = $uidNumber;
    } else {
        $uidNumber = $self->getXidNumberFromRID();
        $optParams{uidNumber} = $uidNumber;
        $self->set('uidNumber', $uidNumber);
        $self->setupUidMapping($uidNumber);
    }
    $zentyalUser = EBox::UsersAndGroups::User->create($params, 0, %optParams);
    $zentyalUser->exists() or
        throw EBox::Exceptions::Internal("Error addding samba user '$uid' to Zentyal");

    $zentyalUser->setIgnoredModules(['samba']);

    my $sc = $self->get('supplementalCredentials');
    my $up = $self->get('unicodePwd');
    my $creds = new EBox::Samba::Credentials(supplementalCredentials => $sc,
                                                 unicodePwd => $up);
    $zentyalUser->setKerberosKeys($creds->kerberosKeys());
}

sub updateZentyal
{
    my ($self) = @_;

    my $uid = $self->get('samAccountName');
    EBox::info("Updating zentyal user '$uid'");

    my $zentyalUser = undef;
    my $gn = $self->get('givenName');
    my $sn = $self->get('sn');
    my $desc = $self->get('description');
    $gn = '-' unless defined $gn;
    $sn = '-' unless defined $sn;
    my $cn = "$gn $sn";
    $zentyalUser = new EBox::UsersAndGroups::User(uid => $uid);
    $zentyalUser->exists() or
        throw EBox::Exceptions::Internal("Zentyal user '$uid' does not exist");

    $zentyalUser->setIgnoredModules(['samba']);
    $zentyalUser->set('givenName', $gn, 1);
    $zentyalUser->set('sn', $sn, 1);
    $zentyalUser->set('description', $desc, 1);
    $zentyalUser->set('cn', $cn, 1);
    $zentyalUser->save();

    my $sc = $self->get('supplementalCredentials');
    my $up = $self->get('unicodePwd');
    my $creds = new EBox::Samba::Credentials(supplementalCredentials => $sc,
                                             unicodePwd => $up);
    $zentyalUser->setKerberosKeys($creds->kerberosKeys());
}

1;
