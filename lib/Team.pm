# -*- Mode: perl; indent-tabs-mode: nil -*-
#
# The contents of this file are subject to the Mozilla Public
# License Version 1.1 (the "License"); you may not use this file
# except in compliance with the License. You may obtain a copy of
# the License at http://www.mozilla.org/MPL/
#
# Software distributed under the License is distributed on an "AS
# IS" basis, WITHOUT WARRANTY OF ANY KIND, either express or
# implied. See the License for the specific language governing
# rights and limitations under the License.
#
# The Original Code is the AgileTools Bugzilla Extension.
#
# The Initial Developer of the Original Code is Pami Ketolainen
# Portions created by the Initial Developer are Copyright (C) 2012 the
# Initial Developer. All Rights Reserved.
#
# Contributor(s):
#   Pami Ketolainen <pami.ketolainen@gmail.com>

use strict;
use warnings;
package Bugzilla::Extension::AgileTools::Team;

use base qw(Bugzilla::Object);

use Bugzilla::Constants;
use Bugzilla::Group;
use Bugzilla::User;
use Bugzilla::Error;
use Bugzilla::Util qw(trim);

use Scalar::Util qw(blessed);
use List::Util qw(first);

use constant DB_TABLE => 'agile_teams';

use constant DB_COLUMNS => qw(
    id
    name
    group_id
    process_id
);

use constant NUMERIC_COLUMNS => qw(
    group_id
    process_id
);

use constant UPDATE_COLUMNS => qw(
    name
    group_id
    process_id
);

use constant VALIDATORS => {
    name => \&_check_name,
};

# Accessors
###########

sub group_id   { return $_[0]->{group_id}; }
sub process_id { return $_[0]->{process_id}; }

sub group {
    my $self = shift;
    $self->{group} ||= Bugzilla::Group->new($self->group_id);
    return $self->{group};
}

# Mutators
##########

sub set_name       { $_[0]->set('name', $_[1]); }
sub set_group_id   { $_[0]->set('group_id', $_[1]); }
sub set_process_id { $_[0]->set('process_id', $_[1]); }

sub set_group {
    my ($self, $value) = @_;
    my $group_id;
    if (ref($value)) {
        $group_id = $value->id;
    } elsif ($value =~ /\d+/) {
        $group_id = $value;
    } else {
        $group_id = Bugzilla::Group->check($value)->id;
    }
    $self->set('group_id', $group_id);
}

# Validators
############

sub _check_name {
    my ($invocant, $name) = @_;
    $name = trim($name);
    $name || ThrowUserError("empty_team_name");

    # If we're creating a Team or changing the name...
    if (!ref($invocant) || lc($invocant->name) ne lc($name)) {
        my $exists = new Bugzilla::Extension::AgileTools::Team({name => $name});
        ThrowUserError("agile_team_exists", { name => $name }) if $exists;

        # Check that there is no group with that name...
        $exists = new Bugzilla::Group({name => $name});
        ThrowUserError("group_exists", { name => $name }) if $exists;
    }
    return $name;
}

# Team member methods
#####################

sub members {
    my $self = shift;
    return [] unless $self->id;
    return $self->group->members_non_inherited();
}

sub add_member {
    my ($self, $member) = @_;
    if (!blessed $member) {
        if ($member =~ /^\d+$/) {
            $member = Bugzilla::User->check({id => $member});
        } else {
            $member = Bugzilla::User->check($member);
        }
    }
    return if defined  first { $_->id == $self->id } @{$member->agile_teams};

    my $dbh = Bugzilla->dbh;

    $dbh->do("INSERT INTO user_group_map (
        user_id, group_id, isbless, grant_type
        ) VALUES (?, ?, ?, ?)", undef,
        ($member->id, $self->group->id, 0, GRANT_DIRECT));
}

sub remove_member {
    my ($self, $member) = @_;
    if (!blessed $member) {
        if ($member =~ /^\d+$/) {
            $member = Bugzilla::User->check({id => $member});
        } else {
            $member = Bugzilla::User->check($member);
        }
    }
    return if !defined first {$_->id == $self->id} @{$member->agile_teams};
    my $dbh = Bugzilla->dbh;

    $dbh->do("DELETE FROM user_group_map
        WHERE user_id = ? AND group_id = ? AND grant_type = ?", undef,
        ($member->id, $self->group->id, GRANT_DIRECT));
}

# Team component methods
########################

sub components {
    return $_[0]->_resposibilites("component");
}

sub add_component {
    return $_[0]->_add_responsibility("component", $_[1]);
}

sub remove_component {
    return $_[0]->_remove_responsibility("component", $_[1]);
}

# Team keyword methods
######################

sub keywords {
    return $_[0]->_resposibilites("keyword");
}

sub add_keyword {
    return $_[0]->_add_responsibility("keyword", $_[1]);
}

sub remove_keyword {
    return $_[0]->_remove_responsibility("keyword", $_[1]);
}


# Responsibility helpers
########################

use constant _RESP_CLASS => {
    component => "Bugzilla::Component",
    keyword => "Bugzilla::Keyword",
};

sub _resposibilites {
    my ($self, $type) = @_;
    my $cache = $type."s";
    my $table = "agile_team_".$type."_map";
    return $self->{$cache} if defined $self->{$cache};
    return [] unless $self->id;

    my $dbh = Bugzilla->dbh;
    my $item_ids = $dbh->selectcol_arrayref(
        "SELECT ".$type."_id FROM ".$table."
         WHERE team_id = ?", undef, $self->id);

    $self->{$cache} = $self->_RESP_CLASS->{$type}->new_from_list($item_ids);
    return $self->{$cache};
}

sub _add_responsibility {
    my ($self, $type, $item) = @_;

    if (!blessed $item) {
        if ($item =~ /^\d+$/) {
            $item = $self->_RESP_CLASS->{$type}->check({id => $item});
        } else {
            ThrowCodeError("bad_arg", { argument => $item,
                    function => "Team::_add_responsibility" });
        }
    }

    my $cache = $type."s";
    my $table = "agile_team_".$type."_map";
    my $dbh = Bugzilla->dbh;
    $dbh->bz_start_transaction();

    # Check that item is not already included
    my $included = $dbh->selectrow_array(
        "SELECT 1 FROM ".$table."
          WHERE team_id = ? AND ".$type."_id = ?",
        undef, ($self->id, $item->id));
    my $rows = 0;
    if (!$included) {
        $rows = $dbh->do("INSERT INTO ".$table."
            (team_id, ".$type."_id) VALUES (?, ?)",
            undef, ($self->id, $item->id));

        # Push the new item in cache if cache has been fetched
        push(@{$self->{$cache}}, $item)
                if defined $self->{$cache};
    }
    $dbh->bz_commit_transaction();
    return $rows;
}

sub _remove_responsibility {
    my ($self, $type, $item) = @_;
    my $item_id;
    if (blessed $item) {
        $item_id = $item->id;
    } elsif ($item =~ /^\d+$/) {
        $item_id = $item;
    } else {
        ThrowCodeError("bad_arg", { argument => $item,
                function => "Team::_remove_responsibility" });
    }

    my $cache = $type."s";
    my $table = "agile_team_".$type."_map";
    my $dbh = Bugzilla->dbh;

    my $rows = $dbh->do(
        "DELETE FROM ".$table."
               WHERE team_id = ? AND ".$type."_id = ?",
               undef, ($self->id, $item_id));

    if ($rows && defined $self->{$cache}) {
        my @items;
        foreach my $obj (@{$self->{$cache}}) {
            next if ($obj->id == $item_id);
            push(@items, $obj);
        }
        $self->{$cache} = \@items;
    }
    return $rows;
}

# Overridden Bugzilla::Object methods
#####################################

sub update {
    my $self = shift;

    my($changes, $old) = $self->SUPER::update(@_);

    if ($changes->{name}) {
        # Reflect the name change on the group
        my $new_name = $changes->{name}->[1];
        $self->group->set_all({
                name => $new_name,
                description => "'" . $new_name . "' team member group",
            }
        );
        $self->group->update();
    }

    if (wantarray) {
        return ($changes, $old);
    }
    return $changes;
}

sub create {
    my ($class, $params) = @_;

    $class->check_required_create_fields($params);
    my $clean_params = $class->run_create_validators($params);

    # Greate the group and put ID in params
    my $group = Bugzilla::Group->create({
            name => $params->{name},
            description => "'" . $params->{name} . "' team member group",
            # isbuggroup = 0 means system group
            isbuggroup => 0,
        }
    );
    $clean_params->{group_id} = $group->id;

    return $class->insert_create_data($clean_params);
}

sub remove_from_db {
    my $self = shift;
    my $group = $self->group;
    $self->SUPER::remove_from_db(@_);

    # We need to trick group to think that its not a system group
    $group->{isbuggroup} = 1;
    $group->remove_from_db();
}

# External team methods
#######################

BEGIN {
    *Bugzilla::User::agile_teams = sub {
        my $self = shift;
        return $self->{agile_teams} if defined $self->{agile_teams};

        my @group_ids = map { $_->id } @{$self->direct_group_membership};
        my $team_ids = Bugzilla->dbh->selectcol_arrayref("
            SELECT id FROM agile_teams
             WHERE group_id IN (". join(",", @group_ids) .")");
        $self->{agile_teams} = Bugzilla::Extension::AgileTools::Team->
                new_from_list($team_ids);
        return $self->{agile_teams};
    };
}



1;

__END__

=head1 NAME

Bugzilla::Extension::AgileTools::Team

=head1 SYNOPSIS

    use Bugzilla::Extension::AgileTools::Team

    my $team = new Bugzilla::Extension::AgileTools::Team(1);

    my $team_id = $team->id;
    my $name = $team->name;
    my $group = $team->group;
    my $group_id = $team->group_id;
    my $process_id = $team->process_id;

    my @members = @{$team->memebers};
    $team->add_member("john.doe@example.com");
    $team->add_member($user_id);
    my $member = Bugzilla::User->check("john.doe@example.com");
    $team->remove_member($member);
    $team->remove_member($user_id);

    my @component_resposibilities = @{$team->components};
    $team->add_component($component_id);
    $team->remove_component($component_id);

    my @keyword_resposibilities = @{$team->keywords};
    $team->add_keyword($keyword_id);
    $team->remove_keyword($keyword_id);

    my $user = new Bugzilla::User(1);
    my @teams = @{$user->agile_teams};

=head1 DESCRIPTION

Team.pm presents a AgileTools Team object inherited from L<Bugzilla::Object>
and has all the same methods, plus the ones described below.

=head1 METHODS


=head2 Memebers

=over

=item C<members>

Description: Gets the list of team members.

Returns:     Array ref of L<Bugzilla::User> objects.


=item C<add_member($user)>

Description: Adds a new member to the team.

Params:      $user - User object, name or id

Notes:       This method does not check permissions to modify the team or group
             So remember to check those first


=item C<remove_member($user)>

Description: Removes a new member from the team.

Params:      $user - User object, name or id

Notes:       This method does not check permissions to modify the team or group
             So remember to check those first

=back


=head2 Responsibilities

=over

=item C<components>

Description: Gets the list of components the team is responsible of

Returns:     Array ref of L<Bugzilla::Component> objects


=item C<add_component($component)>

Description: Adds new component into team responsibilities.

Params:      $component - Component object or id to add.

Returns:     Number of components affected.

Notes:       Throws an error if component with given id does not exist.


=item C<remove_component($component)>

Description: Removes component from team responsibilities

Params:      $component - Component object or id to remove.

Returns:     Number of components affected.


=item C<keywords>

Description: Gets the list of keywords the team is responsible of

Returns:     Array ref of L<Bugzilla::Keyword> objects


=item C<add_keyword($keyword)>

Description: Adds new keyword to team responsibilities

Params:      $keyword - Keyword object or id to add

Returns:     Number of keywords affected


=item C<remove_keyword($keyword)>

Description: Adds new keyword to team responsibilities

Params:      $keyword - Keyword object or id to remove

Returns:     Number of keywords affected

=back


=head1 RELATED METHODS

The L<Bugzilla::User> object is also extended to provide easy access to teams
where particular user is a member.

=over

=item C<Bugzilla::User::agile_teams>

Description: Returns the list of teams the user is member in.

Returns:     Array ref of C<Bugzilla::Extension::AgileTools::Team> objects.

=back
