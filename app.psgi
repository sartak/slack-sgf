#!/usr/bin/perl
use utf8;
use strict;
use warnings;
use Plack::Builder;
use Plack::Request;
use JSON 'decode_json', 'encode_json';
use WWW::Mechanize;
use Games::Go::SGF2misc;

my $access;
my $verify    = $ENV{TOKEN}        or die "env var TOKEN required";
my $client_id = $ENV{OAUTH_CLIENT} or die "env var OAUTH_CLIENT required";
my $secret    = $ENV{OAUTH_SECRET} or die "env var OAUTH_SECRET required";

my @coord = qw(A B C D E F G H J K L M N O P Q R S T);

my %games;

builder {
    enable "Deflater", content_type => ['text/css','text/html','text/javascript','application/javascript','application/json','image/png'];

    # oauth
    mount "/" => sub {
        my $req = Plack::Request->new(shift);
        if (my $code = $req->param('code')) {
            my $mech = WWW::Mechanize->new;
            my $response = $mech->get(
                'https://slack.com/api/oauth.access'.
                '?code='.$code.
                '&client_id='.$client_id.
                '&client_secret='.$secret
            );
            my $res = decode_json($response->decoded_content);
            $access = $res->{access_token};
        }
    };

    # handles the /sgf slack command
    mount "/sgf" => sub {
        my $req = Plack::Request->new(shift);
        my $p = $req->parameters;

        if ($p->{token} ne $verify) {
            return $req->new_response(400)->finalize;
        }

        my $input = $p->{text};
        my $sgf = Games::Go::SGF2misc->new;
        $sgf->parse_string($input);
        my @nodes = @{ $sgf->nodelist->{1}[0] };

        my $meta = $sgf->{gametree}[0]{game_properties};
        my $black = $meta->{PB} ? "$meta->{PB}(B)" : "Black";
        my $white = $meta->{PW} ? "$meta->{PW}(W)" : "White";
        my $title = "$black vs $white";
        $sgf->{_title} = $title;

        my $key = time . rand;
        $games{$key} = $sgf;

        my $body = {
            response_type => "in_channel",
            text          => $sgf->{_title},
            attachments => [
                {
                    text => "Begin review",
                    fallback => "You are unable to review the game",
                    callback_id => $key,
                    color => "#3AA3E3",
                    attachment_type => "default",
                    image_url => "https://app.sartak.org/img?key=$key&position=2",
                    actions => [
                        {
                            name => "move",
                            text => "from beginning",
                            type => "button",
                            value => 3,
                        },
                        {
                            name => "move",
                            text => "from end",
                            type => "button",
                            value => $#nodes,
                        },
                    ],
                },
            ],
        };

        my $res = $req->new_response(200);
        $res->content_type('application/json');
        $res->body(encode_json($body));
        return $res->finalize;
    };

    # handles button clicks
    mount "/im" => sub {
        my $req = Plack::Request->new(shift);
        my $p = decode_json($req->param('payload'));

        if ($p->{token} ne $verify) {
            return $req->new_response(400)->finalize;
        }

        my $key = $p->{callback_id};
        my $sgf = $games{$key};
        my $position = $p->{actions}[0]{value};
        my @nodes = @{ $sgf->nodelist->{1}[0] };
        my $node = $nodes[$position];
        my $data = $sgf->as_perl( $node, 1 );

        my $description = "Move $position";
        if (@{ $data->{moves} } == 1) {
            my $move = $data->{moves}[0];
            my $color = $move->[0];

            my $loc = $move->[1] eq 'PASS' ? 'pass' : 'at ' . $coord[$move->[2]] . ($move->[1]+1);
            $description = "$description: $color $loc";
        }

        my $body = {
            response_type => "ephemeral",
            text => $sgf->{_title},
            attachments => [
                {
                    text => $description,
                    fallback => "You are unable to review the game",
                    callback_id => $key,
                    color => "#3AA3E3",
                    image_url => "https://app.sartak.org/img?key=$key&position=$position",
                    attachment_type => "default",
                    actions => [
                        # Slack limits you to 5 buttons
                        #{
                        #    name => "move",
                        #    text => "⏮️",
                        #    type => "button",
                        #    value => 1,
                        #},
                        {
                            name => "move",
                            text => "⏪",
                            type => "button",
                            value => $position - 10,
                        },
                        {
                            name => "move",
                            text => "◀️️",
                            type => "button",
                            value => $position - 1,
                        },
                        {
                            name => "move",
                            text => "▶️️",
                            type => "button",
                            value => $position + 1,
                        },
                        {
                            name => "move",
                            text => "⏩",
                            type => "button",
                            value => $position + 10,
                        },
                        {
                            name => "move",
                            text => "⏭️",
                            type => "button",
                            value => $#nodes,
                        },
                    ],
                },
            ],
        };

        my $res = $req->new_response(200);
        $res->content_type('application/json');
        $res->body(encode_json($body));
        return $res->finalize;
    };

    # handles serving go game as png
    mount "/img" => sub {
        my $req = Plack::Request->new(shift);
        my $p = $req->parameters;

        my $key = $p->{key};
        my $position = $p->{position};
        my $png_file = "/tmp/$key.$position.png";
        if (!-e $png_file) {

            # the direct-to-png renderer is busted. so render an svg
            # then use imagemagick to convert it to a png. lmao
            my $svg_file = "/tmp/$key.$position.svg";
            if (!-e $svg_file) {
                my $sgf = $games{$key};
                my @nodes = @{ $sgf->nodelist->{1}[0] };
                my $node = $nodes[$position];
                draw($sgf, $node, {filename=> $svg_file, automark => 1, use => 'Games::Go::SGF2misc::SVG'});
            }
            system('convert', '-density', '400', '-resize', '400x400', $svg_file, $png_file);
        }

        open my $fh, '<:raw', $png_file;
        my $res = $req->new_response(200);
        $res->content_type('image/png');
        $res->body($fh);
        return $res->finalize;
    };
};

# copied from Games::Go::SGF2misc with a bugfix for labeling last move
sub draw {
    my $this = shift;
    my $node = shift; my $nm = $node;
    my $argu = shift;
    my %opts = (imagesize=>256, antialias=>0);

    $node = $this->as_perl( $node, 1 ) or croak $this->errstr;

    my $board = $node->{board};
    my $size  = @{$board->[0]}; # inaccurate?

    if( ref($argu) ne "HASH" ) {
        Carp::croak
        "as_image() takes a hashref argument... e.g., {imagesize=>256, etc=>1} or nothing at all.";
    }

    my $package = $argu->{'use'} || 'Games::Go::SGF2misc::GD';
    if ($package =~ /svg/i) {
        $opts{'imagesize'} = '256px';
    }

    @opts{keys %$argu}  = (values %$argu);
    $opts{boardsize}    = $size;
    $opts{filename}     = "$nm.png" unless $opts{filename};

    my $image;
    eval qq( use $package; \$image = $package->new(%opts); );

    $image->drawGoban();

    # draw moves
    for my $i (0..$#{ $board }) {
        for my $j (0..$#{ $board->[$i] }) {
            if( $board->[$i][$j] =~ m/([WB])/ ) {
                #if( $ENV{DEBUG} > 0 ) {
                #    print STDERR "placeStone($1, [$i, $j])\n";
                #}

                # SGFs are $y, $x, the matrix is $x, $y ...
                $image->placeStone(lc($1), [reverse( $i, $j )]);
            }
        }
    }

    my $marks = 0;
    # draw marks
    for my $m (@{ $node->{marks} }) {
        $image->addCircle($m->[3])   if $m->[0] eq "CR";
        $image->addSquare($m->[3])   if $m->[0] eq "SQ";
        $image->addTriangle($m->[3]) if $m->[0] eq "TR";

        $image->addLetter($m->[3], 'X', "./times.ttf") if $m->[0] eq "MA";
        $image->addLetter($m->[3], $m->[4], "./times.ttf") if $m->[0] eq "LB";
        $marks++;
    }

    if ($argu->{'automark'}) {
        unless ($marks) {
            my $moves = $node->{moves};
            foreach my $m (@$moves) {
                $image->addCircle($m->[3]) if $m->[3];
                #$image->addCircle($m->[3]) unless $m->[3];
            }
        }
    }

    if ($package =~ /svg/i) {
        if( $opts{filename} =~ m/.png$/ ) {
            $image->export($opts{'filename'});
        } else {
            $image->save($opts{filename});
        }
    } else {
        if( $opts{filename} =~ m/^\-\.(\w+)$/ ) {
            return $image->dump($1);
        }

        $image->save($opts{filename});
    }
}
