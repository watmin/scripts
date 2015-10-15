#!/usr/bin/perl

use strict;
use warnings;

use Mail::POP3Client;
use Getopt::Long;

my %kickin_ass;
GetOptions(
    'bubble_gum=i' => \$kickin_ass{bubble_gum}
);

if ( not defined $kickin_ass{bubble_gum} ) {
    print "I'm here to destroy email and chew bubble gum, and I still have bubble gum\n";
    exit;
}
elsif ( $kickin_ass{bubble_gum} == 0 ) {
    print "It's time to destroy email and chew bubble gum... and I'm all outta gum..\n";
}

my $nukem = new Mail::POP3Client(
    USER        => 'your@email_account.biz',
    PASSWORD    => '_y0ur3mal3pas$wo7d',
    HOST        => 'pop3.your.isp',
    PORT        => 995,
    USESSL      => 1
);

duke($nukem);


sub duke {
    my ( $nukem ) = @_;

    my @progress = (
        "AAhhh... much better!",
        "Bitchin'!",
        "Boooorn tooo beee wiiiiiiild...",
        "Come get some!",
        "Come on!",
        "Damn....",
        "Damn!",
        "Damn it.",
        "Damn... I'm looking good!",
        "Damn, those alien bastards are gonna pay for shooting up my ride.",
        "Damn, that's the second time those alien bastards shot up my ride!",
        "Damn, you're ugly.",
        "Do, or do not, there is no try.",
        "Get that crap outta here!",
        "Die, you son of a bitch!",
        "Get back to work, you slacker!",
        "Go ahead, make my day.",
        "Gonna rip 'em a new one.",
        "Guess again, freakshow. I'm coming back to town, and the last thing that's gonna go through your mind before you die... is my size-13 boot!",
        "Hail to the king, baby!",
        "Heh, heh, heh... what a mess!",
        "Hmm, that's one 'Doomed' Space Marine.",
        "Holy cow!",
        "Holy shit!",
        "I'll rip your head off and shit down your neck.",
        "I'm gonna get medieval on your asses!",
        "I'm gonna kick your ass, bitch!",
        "I'm gonna put this smack dab on your ass!",
        "I like a good cigar...and a bad woman...",
        "It's down to you and me, you one-eyed freak!",
        "It's time to abort your whole freaking species!",
        "Let God sort 'em out!",
        "Let's rock!",
        "Looks like cleanup on aisle four.",
        "Lucky son of a bitch.",
        "Mess with the best, you will die like the rest",
        "My boot, your face; the perfect couple.",
        "Now this is a force to be reckoned with!",
        "Nuke 'em 'till they glow, then shoot 'em in the dark!",
        "Oh...your ass is grass and I've got the weed-whacker.",
        "Ooh, I needed that!",
        "Ooh, that's gotta hurt.",
        "Piece of Cake.",
        "See you in Hell!",
        "Sometimes I even amaze myself.",
        "Staying alive, staying alive, la.",
        "Suck it down!",
        "Terminated!",
        "This really pisses me off!",
        "This is KTIT, K-Tit! Playing the breast- uhh, the best tunes in town.",
        "That's gonna leave a mark!",
        "What are you waitin' for? Christmas?",
        "What are you? Some bottom-feeding, scum-sucking algae eater?",
        "Where is it?",
        "Who wants some?",
        "Wohoo!",
        "Yeah, piece of cake!",
        "You guys suck!",
        "You're an inspiration for birth control.",
        "Your face, your ass - what's the difference?",
        "Batteries not included!",
        "Confucius say... DIE!",
        "Crouching mutant, hidden pipebomb!",
        "Death before Disco!",
        "Die bitch!",
        "Don't get your panties all in a bunch.",
        "Guns don't kill mutants, I kill mutants.",
        "Half man, half animal, all dead.",
        "Hmmm... That's gonna leave a mark.",
        "Hmmm...the other white meat",
        "I am king of the world, baby!",
        "I'm an equal opportunity asskicker!",
        "I'm not gonna fight you, I'm gonna KICK YOUR ASS!",
        "I don't do windows",
        "I go where I please, and I please where I go. (after rescuing a babe)",
        "I kill bugs...DEAD!",
        "I like big guns, and I cannot lie.",
        "I love the smell of burnt crap in the morning.",
        "I see dead people.",
        "It's a good day to die!",
        "It's clobbering time!",
        "It's my way or... Hell, it's my way!",
        "Life is like a box of ammo.",
        "My gun's bigger than yours.",
        "No token, no ride!",
        "No disassembling required.",
        "Now I'm really pissed off!",
        "Oops, I did it again!",
        "Pucker up, buttercup!",
        "Rest in pieces!",
        "Say 'hello' to my little friend!",
        "Sewer scum!",
        "Should've stayed in the swamp!",
        "So much for the rat pack!",
        "This is why I have games named after me!",
        "Time for mutation-mutilation!",
        "Time for a reboot!",
        "Time to deliver max pain on the A-Train...now where'd I put that subway token?",
        "Time to deworm the Big Apple...",
        "This'll be a barrel of laughs",
        "What am I? A frog?",
        "Who wants to glow in the dark?",
        "You're goin' down faster than the XFL!",
        "You're starting to bug me.",
        "You are the missing link. Goodbye.",
        "Your kung-fu's through!",
        "You talkin' to me?",
        "I oughta break a broomhandle off in your ass."
    );

    for ( my $scum = $nukem->Count ; $scum > 0 ; $scum-- ) {
        $nukem->Delete($scum);
        if ( ( $scum % 500 ) eq 0 ) { printf "%s\n", $progress[rand @progress] }
    }

    $nukem->Close;

    print "Damn, I'm good!\n";
}
