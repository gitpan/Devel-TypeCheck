package B::Typecheck;

use strict;
use B;
use B::Asmdata qw(@specialsv_name);
use Carp;
use Scalar::Util qw(blessed);
use English;
require 'opnames.ph';

# Base of type checking
use Devel::TypeCheck::Type;
use Devel::TypeCheck::Util;

# Include branch types
use Devel::TypeCheck::Type::Mu;
use Devel::TypeCheck::Type::Eta;
use Devel::TypeCheck::Type::Kappa;
use Devel::TypeCheck::Type::Nu;
use Devel::TypeCheck::Type::Rho;

# Include terminal types
use Devel::TypeCheck::Type::Av;
use Devel::TypeCheck::Type::Hv;
use Devel::TypeCheck::Type::Cv;
use Devel::TypeCheck::Type::Io;
use Devel::TypeCheck::Type::Pv;
use Devel::TypeCheck::Type::Iv;
use Devel::TypeCheck::Type::Dv;

# Type variables
use Devel::TypeCheck::Type::Var;

# The environment, GAMMA
use Devel::TypeCheck::Environment;
use Devel::TypeCheck::Glob2type;
use Devel::TypeCheck::Pad2type;

# Names of CVs to type check
our @cvnames;

# Set of CVs to type check
our @roots;

# Whether or not to check the main body
our $mainRoot = FALSE;

# Symbol to type lookup for global symbols
our $glob2type;

# Position information for error reporting
our $globalLine = "";
our $globalFile = "";

# For output
our $depth = 0;
our $depthIncrement = 4;
our $opcodes = 0;

# Required function for O(3pm) use.  Adapted from B::Concise
sub compile {
    my @options = grep(/^-/, @_);

    @cvnames = grep(!/^-/, @_);

    setVerbose(FALSE);
    for my $o (@options) {
        if ($o eq "-verbose") {
	    setVerbose(TRUE);
	} elsif ($o eq "-main") {
	    $mainRoot = TRUE;
        } else {
            warn "Option $o unrecognized";
        }
    }

    return \&callback;
}

# Fully qualified terminal types
our $AV = Devel::TypeCheck::Type::Mu->new(Devel::TypeCheck::Type::Av->new());
our $HV = Devel::TypeCheck::Type::Mu->new(Devel::TypeCheck::Type::Hv->new());
our $CV = Devel::TypeCheck::Type::Mu->new(Devel::TypeCheck::Type::Cv->new());
our $IO = Devel::TypeCheck::Type::Mu->new(Devel::TypeCheck::Type::Io->new());
our $PV = Devel::TypeCheck::Type::Mu->new(Devel::TypeCheck::Type::Kappa->new(Devel::TypeCheck::Type::Pv->new()));
our $IV = Devel::TypeCheck::Type::Mu->new(Devel::TypeCheck::Type::Kappa->new(Devel::TypeCheck::Type::Nu->new(Devel::TypeCheck::Type::Iv->new())));
our $DV = Devel::TypeCheck::Type::Mu->new(Devel::TypeCheck::Type::Kappa->new(Devel::TypeCheck::Type::Nu->new(Devel::TypeCheck::Type::Dv->new())));

# Special value, unique in references, for use in the *Proto functions
our $ANY = \0;

# Sane wrapper around raw unify
sub myUnify {
    my ($env, $var, @vars) = @_;

    if (defined($var)) {
	
	my $acc = $var;
	for my $i (@vars) {
	    if (!defined($i)) {
		confess("Tried to unify an undefined value");
	    }

	    my $oldacc = $acc;

	    if ($acc->is(Devel::TypeCheck::Type::H()) && $i->is(Devel::TypeCheck::Type::P())) {
		verbose(" " x $depth, "  Enacting MH ~= MKPMH rule");
		$i = $i->deref;
	    }

	    if ($i->is(Devel::TypeCheck::Type::H()) && $acc->is(Devel::TypeCheck::Type::P())) {
		verbose(" " x $depth, "  Enacting MH ~= MKPMH rule");
		$acc = $acc->deref;
	    }

	    verbose_(" " x $depth, "  unify(", $oldacc->str($env), ", ", $i->str($env), ") = ");
	    $acc = $env->unify($acc, $i);
	    verbose($acc?$acc->str($env):"FAIL");

	    if (!$acc) {
		die("Could not unify " . $env->find($oldacc)->str($env) . " and " . $env->find($i)->str($env) .
		    " at line " . $globalLine . ", file " . $globalFile . "\n");
	    }
	}

	return $env->find($acc);
    } else {
	return undef;
    }
}

# Type the children of a given operator
sub typeOpChildren {
    my ($op, $pad2type, $env, $cv) = @_;

    # If the operator has kids, the type of the NULL op is the type of the last kid
    # Otherwise, this operator is untyped
    
    my $result;
    my @returns;
    
    if ($op->flags & B::OPf_KIDS()) {
	for (my $kid = $op->first; $$kid; $kid = $kid->sibling) {
	    # Type the kid
	    my ($s, $r) = typeOp($kid, $pad2type, $env, $cv, SCALAR());
	    
	    # Overwrite the result
	    $result = $s;
	    
	    # Set up unify of return values from down in the tree
	    push(@returns, $r) if (defined($r));
	}
    }
    
    return ($result, myUnify($env, @returns));
}

sub typeOpChildren_ {
    my ($op, $pad2type, $env, $cv) = @_;

    # If the operator has kids, the type of the NULL op is the type of the last kid
    # Otherwise, this operator is untyped
    
    my @results;
    my @returns;
    
    if ($op->flags & B::OPf_KIDS()) {
	for (my $kid = $op->first; $$kid; $kid = $kid->sibling) {
	    # Type the kid
	    my ($s, $r) = typeOp($kid, $pad2type, $env, $cv, SCALAR());
	    
	    # Overwrite the result
	    push(@results, $s) if (defined($s));
	    
	    # Set up unify of return values from down in the tree
	    push(@returns, $r) if (defined($r));
	}
    }
    
    return (myUnify($env, @results), myUnify($env, @returns));
}

sub typeRest {
    my ($kid, $pad2type, $env, $cv) = @_;

    my @rets;

    for ( ; $$kid; $kid = $kid->sibling) {
	my ($t, $r) = typeOp($kid, $pad2type, $env, $cv);
	push(@rets, $r) if ($r);
    }

    return myUnify($env, @rets);
}

sub typeProto {
    my ($op, $pad2type, $env, $cv, @proto) = @_;
    
    my $index = 0;
    my @rets;
    if ($op->flags & B::OPf_KIDS()) {
	my $type = $op->first->type;
	if ($type != OP_PUSHMARK() &&
	    $type != OP_NULL()) {
	    die("Operator is not a function-call type.  Cannot use typeProto()");
	}
	
	for (my $kid = $op->first->sibling; $$kid; $kid = $kid->sibling) {
	    my ($t, $r);
	    if (($proto[$index]) == $ANY) {
		$r = typeRest($kid, $pad2type, $env, $cv);
		push(@rets, $r) if ($r);
		last;
	    } elsif (($proto[$index]) == $AV) {
		($t, $r) = typeOp($kid, $pad2type, $env, $cv, LIST());
	    } else {
		($t, $r) = typeOp($kid, $pad2type, $env, $cv, SCALAR());
	    }
	    myUnify($env, $t, $proto[$index]);
	    push(@rets, $r) if ($r);
	    $index++;
	    die ("Too many arguments") if ($index > ($#proto + 1));
	}
    }

    return (myUnify($env, @rets), ($#proto + 1) - $index);
}

sub typeProtoOp {
    my ($op, $pad2type, $env, $cv, @proto) = @_;
    
    my $index = 0;
    my @rets;
    if ($op->flags & B::OPf_KIDS()) {
	for (my $kid = $op->first->sibling; $$kid; $kid = $kid->sibling) {
	    my ($t, $r);
	    if (($proto[$index]) == $ANY) {
		$r = typeRest($kid, $pad2type, $env, $cv);
		push(@rets, $r) if ($r);
		last;
	    } elsif (($proto[$index]) == $AV) {
		($t, $r) = typeOp($kid, $pad2type, $env, $cv, LIST());
	    } else {
		($t, $r) = typeOp($kid, $pad2type, $env, $cv, SCALAR());
	    }
	    myUnify($env, $t, $proto[$index]);
	    push(@rets, $r) if ($r);
	    $index++;
	    die ("Too many arguments") if ($index > ($#proto + 1));
	}
    }

    return (myUnify($env, @rets), ($#proto + 1) - $index);
}

# Perl conflates the use of rv2XX operators for references, globs, and
# references to globs.  This does it's best to disambiguate that.
sub rvConflate {
    my ($env, $ref, $XX) = @_;

    if (!defined($ref)){
	confess("shit");
    }

    # If $ref is a VAR, unify $ref and RHO($XX), and be done with the
    # sordid business
    if ($ref->type == Devel::TypeCheck::Type::VAR()) {
	myUnify($env, $ref, $env->genRho($XX));
	return $XX;
    }

    # If it's a glob
    if ($ref->is(Devel::TypeCheck::Type::H())) {
      RVC_ISETA:

	# If we're looking for the KAPPA part of the glob
	if ($XX->is(Devel::TypeCheck::Type::K())) {
	    # Project the K from the H
	    $ref = $ref->deref;

	    # Unify it with XX
	    myUnify($env, $ref, $XX);
	}

	# $XX is the type we want, after all
	return($XX);

    # If it's a reference
    } elsif ($ref->is(Devel::TypeCheck::Type::P())) {
	$ref = $ref->deref;

	# Stupid hack alert: these operators do the same thing if $ref
	# is a glob or a ref to a glob
	goto RVC_ISETA if ($ref->is(Devel::TypeCheck::Type::H()));

	# Make sure whatever we dereferenced matches the type we want
	myUnify($env, $ref, $XX);

	return($XX);
    } else {
	confess("Could not dereference through rvConflate");
	return undef;
    }
}

sub getPvConst {
    my ($op, $cv) = @_;

    my $sv = $op->sv;

  RETRY_PVCONST:
    my $class = B::class($sv);

    if ($class eq "PV") {
	return $sv->PV;
    } elsif ($class eq "SPECIAL") {
	$sv = (($cv->PADLIST()->ARRAY())[1]->ARRAY)[$op->targ];
	goto RETRY_PVCONST;
    } else {
	die("Can't get PV constant out of $class");
    }

}

sub constructConst {
    my ($sv, $cv, $op, $env) = @_;

  RETRY_CONST:
    my $class = B::class($sv);

    if ($class eq "PV") {
	return $PV;

    } elsif ($class eq "IV") {
	return $IV;

    } elsif ($class eq "NV") {
	# Constants of type NV are always doubles
	return $DV;

    } elsif ($class eq "RV") {
	return $env->genRho(constructConst($sv->RV, $cv, $op, $env));

    } elsif ($class eq "PVMG") {
	# We have no idea how this might be used, so punt, but make
	# sure whatever uses it, uses it consistently.
	return $env->fresh();

    } elsif ($class eq "PVNV") {

	return $env->freshNu();
	
    } elsif ($class eq "SPECIAL") {
	$sv = (($cv->PADLIST()->ARRAY())[1]->ARRAY)[$op->targ];
	goto RETRY_CONST;

    } else {
	die("Cannot construct a type for referent type $class");
    }
}

# For comparing context
sub LIST { return 0 };
sub SCALAR { return 1 };

sub contextPick {
    my ($context, $type) = @_;
    if ($context == LIST()) {
	return $AV;
    } else {
	return $type;
    }
}
	
sub typeOp {
    my ($op, $pad2type, $env, $cv, $context) = @_;

    $opcodes++;

    $depth += $depthIncrement;

    verbose(" " x $depth, ($context)?"S":"L", ":", $op->name, " {");

    # verbose(" " x $depth, $op->name, " {");

    my ($realResult, $realReturn);

    confess("op is null") if (!defined($op));
    confess("pad2type is null") if (!defined($pad2type));
    confess("env is null") if (!defined($env));
    confess("cv is null") if (!defined($cv));

    my $t = $op->type;

    if ($t == OP_NULL()     ||
	$t == OP_LIST()     || # This one always gets factored out
	$t == OP_LEAVELOOP()||
	$t == OP_ENTERTRY() ||
	$t == OP_ENTERLOOP()||
        $t == OP_ENTER()    ||
	$t == OP_LINESEQ()  ||
	$t == OP_SCOPE()) {

	($realResult, $realReturn) = typeOpChildren($op, $pad2type, $env, $cv);
	$realResult = $AV if ($context == LIST());

    } elsif ($t == OP_LEAVESUB()) {

	($realResult, $realReturn) = typeOpChildren($op, $pad2type, $env, $cv);

	if (defined($realReturn)) {
	    if (defined($realResult)) {
		$realReturn = myUnify($env, $realResult, $realReturn);
	    }
	} else {
	    if (defined($realResult)) {
		$realReturn = $realResult;
	    }
	}	    

    } elsif ($t == OP_LEAVE()) {
	
	# No result type for leave or scope
	($realResult, $realReturn) = (undef, (typeOpChildren($op, $pad2type, $env, $cv))[1])

    } elsif ($t == OP_LEAVETRY()) {

	my ($t, $r) = typeOpChildren($op, $pad2type, $env, $cv);
	($realResult, $realReturn) = (myUnify($env, $t, $r), undef);

    } elsif ($t == OP_ENTERSUB()) {

	# The children are the parameters of the function
	my ($t, $r) = typeOpChildren($op, $pad2type, $env, $cv);

	($realResult, $realReturn) = ($env->fresh(), $r);
	
    } elsif ($t == OP_ENTEREVAL() || 
	     $t == OP_DOFILE()) {

	# Make sure we're passing it a PV
	my ($t, $r) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	myUnify($env, $t, $PV);

	# Generate a new type variable, since the return might be anything
	($realResult, $realReturn) = ($env->fresh(), $t);

    } elsif ($t == OP_ENTERITER()) {

	# The first operand is a dead pushmark, so just ignore it

	# The second operand is the list
	my ($t, $r) = typeOp($op->first->sibling, $pad2type, $env, $cv, LIST());
	myUnify($env, $t, $AV);

	# If the third argument is there, then it's a glob reference
	# to the variable that we're iterating over.
	my $targ = $op->targ;
	if ($targ) {
	    # No third argument, iterator is a lexically scoped variable
	    my $pad = $pad2type->get($targ, $env);
	    myUnify($env, $pad, $env->freshKappa);
	} else {
	    ($t, $r) = typeOp($op->first->sibling->sibling, $pad2type, $env, $cv, SCALAR());

	    myUnify($env, $t, $env->freshEta);
	}

    } elsif ($t == OP_ITER()) {
	
	($realResult, $realReturn) = ($env->freshKappa, undef);

    } elsif ($t == OP_STUB()) {

	($realResult, $realReturn) = (contextPick($context, $env->fresh), undef);

    } elsif ($t == OP_PRINT()) {

	# The children are the parameters of the operator
	my ($t, $r) = typeOpChildren($op, $pad2type, $env, $cv);

	($realResult, $realReturn) = ($IV, $r);
	
    } elsif ($t == OP_INT()) {

	# Can be used as a coercion from DV to IV, so accept Nu
	my ($ot, $or) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	myUnify($env, $ot, $env->freshNu);
	($realResult, $realReturn) = ($IV, $or);

    } elsif ($t == OP_PREINC() ||
	     $t == OP_PREDEC() ||
	     $t == OP_POSTINC()||
	     $t == OP_POSTDEC()) {
	# Unary number operators

	my ($ot, $or) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	myUnify($env, $ot, $env->freshNu);
	($realResult, $realReturn) = ($ot, $or);

    } elsif ($t == OP_NOT()      ||
	     $t == OP_NEGATE()   ||
	     $t == OP_I_NEGATE() ||
	     $t == OP_I_PREINC() ||
	     $t == OP_I_PREDEC() ||
	     $t == OP_I_POSTINC()||
	     $t == OP_I_POSTDEC()||
	     $t == OP_COMPLEMENT()) {
	# Unary number operators that are strict in IV

	my ($ot, $or) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	myUnify($env, $ot, $IV);
	($realResult, $realReturn) = ($IV, $or);

    } elsif ($t == OP_RAND()) {
	# Operand is optional
       
	my $class = B::class($op);

	if ($class eq "UNOP") {
	    my ($ot, $or) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	    myUnify($env, $ot, $env->freshNu)
	}

	($realResult, $realReturn) = ($DV, undef);

    } elsif ($t == OP_EQ() ||
	     $t == OP_NE()) {

	# Have to be able to compare pointers
	my ($ft, $fr) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	my ($lt, $lr) = typeOp($op->last, $pad2type, $env, $cv, SCALAR());

	if ((defined($ft) && $ft->is(Devel::TypeCheck::Type::PV())) || (defined($lt) && $lt->is(Devel::TypeCheck::Type::PV()))) {
	    die("Cannot use numeric comparison (== or !=) to compare strings");
	}

	($realResult, $realReturn) = (myUnify($env, $ft, $lt), myUnify($env, $fr, $lr));

    } elsif ($t == OP_ADD()        ||
	     $t == OP_SUBTRACT()   ||
	     $t == OP_MULTIPLY()   ||
	     $t == OP_MODULO()     ||
	     $t == OP_LT()         ||
	     $t == OP_GT()         ||
	     $t == OP_LE()         ||
	     $t == OP_GE()         ||
	     $t == OP_NCMP()) {
	# Binary number operators

	# Both sides should be unified with Nu, and resulting
	# expression type is Nu.

	my ($ft, $fr) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	my ($lt, $lr) = typeOp($op->last, $pad2type, $env, $cv, SCALAR());
	
	# Bind both to an incomplete Nu value.
	$ft = myUnify($env, $ft, $env->freshNu);
	$lt = myUnify($env, $lt, $env->freshNu);

	if ($ft->is(Devel::TypeCheck::Type::DV()) ||
	    $lt->is(Devel::TypeCheck::Type::DV())) {

	    # Bind up incomplete types to whatever we're going to
	    # return.  No more than one is incomplete
	    if (! $ft->complete) {
		# $ft is incomplete Nu
		myUnify($env, $ft, $DV);
	    } elsif (! $lt->complete) {
		# $lt is incomplete Nu
		myUnify($env, $lt, $DV);
	    }

	    $realResult = $DV;
	} elsif ($ft->is(Devel::TypeCheck::Type::IV()) ||
		 $lt->is(Devel::TypeCheck::Type::IV())) {

	    # Bind up incomplete types to whatever we're going to
	    # return.  No more than one is incomplete
	    if (! $ft->complete) {
		# $ft is incomplete Nu
		myUnify($env, $ft, $IV);
	    } elsif (! $lt->complete) {
		# $lt is incomplete Nu
		myUnify($env, $lt, $IV);
	    }

	    $realResult = $IV;
	} else {
	    $realResult = myUnify($env, $ft, $lt);
	}
	
	$realReturn = myUnify($env, $fr, $lr);

    } elsif ($t == OP_DIVIDE()) {

	my ($ft, $fr) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	my ($lt, $lr) = typeOp($op->last, $pad2type, $env, $cv, SCALAR());
	
	# Bind both to an incomplete Nu value.
	$ft = myUnify($env, $ft, $env->freshNu);
	$lt = myUnify($env, $lt, $env->freshNu);

	($realResult, $realReturn) = ($DV, myUnify($env, $fr, $lr));
    } elsif ($t == OP_ATAN2() ||
	     $t == OP_SIN()   ||
	     $t == OP_COS()   ||
	     $t == OP_EXP()   ||
	     $t == OP_LOG()   ||
	     $t == OP_SQRT()  ||
	     $t == OP_HEX()   ||
	     $t == OP_OCT()   ||
	     $t == OP_POW()   ||
	     $t == OP_ABS()) {

	my ($t, $r) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	
	# Bind to an incomplete Nu value.
	$t = myUnify($env, $t, $env->freshNu);

	($realResult, $realReturn) = ($DV, $r);
	
    } elsif ($t == OP_I_ADD()      ||
	     $t == OP_I_SUBTRACT() ||
	     $t == OP_I_MULTIPLY() ||
	     $t == OP_I_DIVIDE()   ||
	     $t == OP_I_MODULO()   ||
	     $t == OP_I_LT()       ||
	     $t == OP_I_GT()       ||
	     $t == OP_I_LE()       ||
	     $t == OP_I_GE()       ||
	     $t == OP_I_EQ()       ||
	     $t == OP_I_NE()       ||
	     $t == OP_I_NCMP()     ||
	     $t == OP_BIT_AND()    ||
	     $t == OP_BIT_OR()     ||
	     $t == OP_BIT_XOR()    ||
	     $t == OP_SETPGRP()    ||
	     $t == OP_LEFT_SHIFT() ||
	     $t == OP_RIGHT_SHIFT()) {
	# Binary number operators that are strict in IV

	my ($ft, $fr) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	my ($lt, $lr) = typeOp($op->last, $pad2type, $env, $cv, SCALAR());
	
	myUnify($env, $ft, $IV);
	myUnify($env, $lt, $IV);
	
	($realResult, $realReturn) = ($IV, myUnify($env, $fr, $lr));

    } elsif ($t == OP_SEQ() ||
	     $t == OP_SNE() ||
	     $t == OP_SLT() ||
	     $t == OP_SGT() ||
	     $t == OP_SLE() ||
	     $t == OP_SGE() ||
	     $t == OP_SCMP()) {
	# Binary comparison operators

	# Both sides should be unified with PV, but resulting
	# expression type is NV.

	my ($ft, $fr) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	my ($lt, $lr) = typeOp($op->last, $pad2type, $env, $cv, SCALAR());
	
	myUnify($env, $ft, $PV);
	myUnify($env, $lt, $PV);
	
	($realResult, $realReturn) = ($IV, myUnify($env, $fr, $lr));

    } elsif ($t == OP_CONCAT()) {

	# Both sides should be unified with Ka, and resulting
	# expression type is PV.

	my ($ft, $fr) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	my ($lt, $lr) = typeOp($op->last, $pad2type, $env, $cv, SCALAR());
	
	myUnify($env, $ft, $env->freshKappa);
	myUnify($env, $lt, $env->freshKappa);
	
	($realResult, $realReturn) = ($PV, myUnify($env, $fr, $lr));

    } elsif ($t == OP_GELEM()) {

	my ($ft, $fr) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	my ($lt, $lr) = typeOp($op->last, $pad2type, $env, $cv, SCALAR());

	myUnify($env, $ft, $env->freshEta($env));
	myUnify($env, $lt, $PV);

	my $const = getPvConst($op->last, $cv);
	my $r = myUnify($env, $fr, $lr);

	if ($const eq "SCALAR") {
	    ($realResult, $realReturn) = ($env->genRho($ft->deref), $r);
	} elsif ($const eq "IO" ||
		 $const eq "FILEHANDLE") {
	    ($realResult, $realReturn) = ($env->genRho($IO), $r);
	} elsif ($const eq "ARRAY") {
	    ($realResult, $realReturn) = ($env->genRho($AV), $r);
	} elsif ($const eq "HASH") {
	    ($realResult, $realReturn) = ($env->genRho($HV), $r);
	} elsif ($const eq "CODE") {
	    ($realResult, $realReturn) = ($env->genRho($CV), $r);
	} elsif ($const eq "GLOB") {
	    ($realResult, $realReturn) = ($env->genRho($ft), $r);
	} else {
	    die("Unknown *foo{THING} syntax on $const");
	}

    } elsif ($t == OP_GVSV()) {

	# Get the type of the referencing GV.  I don't fully
	# understand the following line.  It was borrowed from
	# B/Concise.pm.
	my $gv = (($cv->PADLIST->ARRAY)[1]->ARRAY)[$op->padix];
	my $tgv = $glob2type->get($gv->SAFENAME(), $env);
	
	# Project the type of the referent SV.  $tgv is guaranteed to
	# be an instance of Devel::TypeCheck::Type::Eta.
	($realResult, $realReturn) = ($tgv->deref, undef);

    } elsif ($t == OP_GV()) {

	# Just get the GV
	my $gv = (($cv->PADLIST->ARRAY)[1]->ARRAY)[$op->padix];
	my $tgv = $glob2type->get($gv->SAFENAME(), $env);

	($realResult, $realReturn) = ($env->genRho($tgv), undef);

    } elsif ($t == OP_RV2GV()) {

	my ($t, $r) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	
	# Guarantee that we can dereference something
	myUnify($env, $t, $env->freshRho());

	my $d = $env->find($t)->deref;

	myUnify($env, $d, $env->freshEta($env));
	($realResult, $realReturn) = ($d, $r);

    } elsif ($t == OP_RV2SV()) {

        my ($t, $r) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	my $d = rvConflate($env, $t, $env->freshKappa());
	($realResult, $realReturn) = ($d, $r);

    } elsif ($t == OP_RV2AV()) {
	
        my ($t, $r) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	my $d = rvConflate($env, $t, $AV);
	($realResult, $realReturn) = ($AV, $r);

    } elsif ($t == OP_RV2HV()) {
	
        my ($t, $r) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	my $d = rvConflate($env, $t, $HV);
	($realResult, $realReturn) = ($HV, $r);

    } elsif ($t == OP_RV2CV()) {
	
        my ($t, $r) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	my $d = rvConflate($env, $t, $CV);
	($realResult, $realReturn) = ($CV, $r);

    } elsif ($t == OP_ANONCODE()) {
	
	($realResult, $realReturn) = ($CV, undef);

    } elsif ($t == OP_PROTOTYPE()) {

	my ($t, $r) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	myUnify($env, $t, $CV);

	($realResult, $realReturn) = ($PV, $r);

    } elsif ($t == OP_REFGEN()) {

	my ($t, $r) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());

	if ($t->is(Devel::TypeCheck::Type::AV())) {
	    # If the operand is an array, return an array
	    ($realResult, $realReturn) = ($AV, $r);
	} else {
	    # Otherwise, return RHO( operand type )
	    ($realResult, $realReturn) = ($env->genRho($t), $r);
	}

    } elsif ($t == OP_SREFGEN()) {

	my ($t, $r) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	($realResult, $realReturn) = ($env->genRho($t), $r);

    } elsif ($t == OP_REF()) {

	# Can be passed anything
	my ($t, $r) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	
	# Returns a string
	($realResult, $realReturn) = ($PV, $r);

    } elsif ($t == OP_BLESS()) {

	my ($t, $r) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	
	if (${$op->first->sibling}) {
	    my ($st, $sr) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	    myUnify($env, $st, $PV);
	    $r = myUnify($env, $r, $sr);
	}

	($realResult, $realReturn) = ($t, $r);

    } elsif ($t == OP_ANONLIST()) {

	my ($t, $r) = typeOpChildren($op->first, $pad2type, $env, $cv);

	($realResult, $realReturn) = ($AV, $r);

    } elsif ($t == OP_AELEMFAST()) {

	# AELEMFAST is an optimization that's only used on globs.  All
	# we know is that the resulting type is a KAPPA of some sort.
	($realResult, $realReturn) = ($env->freshKappa(), undef);
    
    } elsif ($t == OP_AELEM()) {

	my ($ft, $fr) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	my ($lt, $lr) = typeOp($op->last, $pad2type, $env, $cv, SCALAR());

	# First must be an AV
	myUnify($env, $ft, $AV);

	# Last must be an IV
	myUnify($env, $lt, $IV);
	
	# Resulting type is a generic KAPPA
	($realResult, $realReturn) = ($env->freshKappa(), undef);

    } elsif ($t == OP_HELEM()) {       

	my ($ft, $fr) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	my ($lt, $lr) = typeOp($op->last, $pad2type, $env, $cv, SCALAR());

	# First must be an HV
	myUnify($env, $ft, $HV);

	# Last must be an NV (actually, an IV, but we can't disambiguate)
	myUnify($env, $lt, $PV);
	
	# Resulting type is a generic KAPPA
	($realResult, $realReturn) = ($env->freshKappa(), undef);
       
    } elsif ($t == OP_SASSIGN()) {
	
	# At this point the type check is flow insensitive, and we're
	# not doing any subtyping.  Thus, all we have to do is unify
	# both sides with each other.

	my ($ft, $fr) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	my ($lt, $lr) = typeOp($op->last, $pad2type, $env, $cv, SCALAR());

	($realResult, $realReturn) = (myUnify($env, $ft, $lt),
		myUnify($env, $fr, $lr));

    } elsif ($t == OP_AASSIGN()) {

	my ($lhs, $rhs);
	my @rets;

	# Get lhs
	if ($op->last->name eq "null") {
	    $lhs = $op->last->first->sibling;
	} else {
	    die("Don't know how to deal with non-op_null child of op_aassign on lhs");
	}

	# Get rhs
	if ($op->first->name eq "null") {
	    $rhs = $op->first->first->sibling;
	} else {
	    die("Don't know how to deal with non-op_null child of op_aassign on rhs");
	}

	# Foreach on lhs
	for ($lhs; $$lhs && $$rhs; $lhs = $lhs->sibling, $rhs = $rhs->sibling) {
	    
	    # typecheck lhs
	    my ($lt, $lr) = typeOp($lhs, $pad2type, $env, $cv, LIST());
	    push(@rets, $lr) if ($lr);
	    confess("Type from lhs is undefined") unless ($lt);

	    # typecheck rhs
	    my ($rt, $rr) = typeOp($rhs, $pad2type, $env, $cv, LIST());
	    push(@rets, $rr) if ($rr);
	    die("Type from rhs is undefined") unless ($rt);

	    # if neither has been inferenced as an AV, try unifying them
	    if (! ($lt->is(Devel::TypeCheck::Type::AV()) ||
		   $rt->is(Devel::TypeCheck::Type::AV()) ||
		   $lt->is(Devel::TypeCheck::Type::HV()) ||
		   $rt->is(Devel::TypeCheck::Type::HV()))) {
		myUnify($env, $lt, $rt);
	    } else {
		# Otherwise, punt
		last;
	    }
	}

	$lhs = $lhs->sibling if ($$lhs);
	$rhs = $rhs->sibling if ($$rhs);
	    
	# At this point, we don't know what is going where, so just
	# typecheck each branch in a list context, but don't unify
	# anything.
	for ($lhs; $$lhs; $lhs = $lhs->sibling) {
	    my ($t, $r) = typeOp($lhs, $pad2type, $env, $cv, LIST());
	    push(@rets, $r) if ($r);
	}
	    
	for ($rhs; $$rhs; $rhs = $rhs->sibling) {
	    my ($t, $r) = typeOp($rhs, $pad2type, $env, $cv, LIST());
	    push(@rets, $r) if ($r);
	}
	    
	($realResult, $realReturn) = ($AV, myUnify($env, @rets));

    } elsif ($t == OP_CONST()) {

	my $sv = $op->sv;
	($realResult, $realReturn) = constructConst($sv, $cv, $op, $env);

    } elsif ($t == OP_SPLIT()) {
	
	# First is always the pushre pmop, second is the string, and
	# third is the count.  

	if ($context == SCALAR() &&
	    !defined($op->first->pmreplroot())) {
	    warn("split in a scalar context is deprecated");
	}

	my ($st, $sr) = typeOp($op->first->sibling, $pad2type, $env, $cv, SCALAR());
	myUnify($env, $st, $PV);

	my ($ct, $cr) = typeOp($op->first->sibling->sibling, $pad2type, $env, $cv, SCALAR());
	myUnify($env, $ct, $IV);
	
	($realResult, $realReturn) = ($AV, myUnify($env, $sr, $cr));

    } elsif ($t == OP_JOIN()) {

	# First is a pushmark, second is a PV, rest are type checked
	# in a list context but not unified
	my ($t, $r) = typeOp($op->first->sibling, $pad2type, $env, $cv, SCALAR());
	myUnify($env, $t, $PV);

	my @rets;
	push(@rets, $r) if ($r);

	for (my $kid = $op->first->sibling->sibling; $$kid; $kid = $kid->sibling) {
	    ($t, $r) = typeOp($kid, $pad2type, $env, $cv, LIST());
	    push(@rets, $r) if ($r);
	}

	($realResult, $realReturn) = ($PV, myUnify($env, @rets));

    } elsif ($t == OP_MATCH()) {

	my ($t, $r) = (undef, undef);

	if ($op->flags & B::OPf_KIDS()) {
	    ($t, $r) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	    myUnify($env, $t, $PV);
	}

	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_SUBST()) {

	my ($t, $r);
	my @rets;

	my $cur = $op->first;
	if ($op->flags & B::OPf_STACKED()) {
	    ($t, $r) = typeOp($cur, $pad2type, $env, $cv, SCALAR());
	    myUnify($env, $t, $PV);
	    push(@rets, $r) if ($r);
	    $cur = $op->last;
	}

	($t, $r) = typeOp($cur, $pad2type, $env, $cv, SCALAR());
	push(@rets, $r) if ($r);

	($realResult, $realReturn) = ($IV, myUnify($env, @rets));

    } elsif ($t == OP_SUBSTCONT()) {

	my ($t, $r) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	myUnify($env, $t, $PV);
	
	($realResult, $realReturn) = ($PV, $r);

    } elsif ($t == OP_NEXTSTATE() ||
	     $t == OP_DBSTATE() ||
	     $t == OP_SETSTATE()) {

	# Has no effect on typing

	verbose(" " x $depth, "  line ", $op->line, ", file ", $op->file);
	# Set some globals for error reporting purposes
	$globalLine = $op->line;
	$globalFile = $op->file;

	($realResult, $realReturn) = (undef, undef);

    } elsif ($t == OP_COND_EXPR() ||
	     $t == OP_AND() ||
	     $t == OP_OR()) {

	# All LOGOPs
	my @types;
	my @rets;

	# First operand should unify with Kappa.  This makes sense,
	# since non-zero numbers, non-empty strings, and non-undef
	# references are true, and correspondingly zero, the empty
	# string, and undef are false.  This precludes testing for
	# empty aggregate data structures.
	my ($ft, $fr) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	myUnify($env, $ft, $env->freshKappa());
	push(@rets, $fr) if (defined($fr));

	# Remaining operands should unify together
	for (my $kid = $op->first->sibling; $$kid; $kid = $kid->sibling) {
	    my ($t, $r) = typeOp($kid, $pad2type, $env, $cv, SCALAR());
	    push(@types, $t) if (defined($t));
	    push(@rets, $r) if (defined($r));
	}

	my $t = myUnify($env, @types);
	my $r = myUnify($env, @rets);
	($realResult, $realReturn) = ($t, $r);

    } elsif ($t == OP_XOR()) {

	my ($r, $missing) = typeProtoOp($op, $pad2type, $env, $cv, ($env->freshKappa, $env->freshKappa));
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_SCALAR()) {

	# Get ready for an ugly hack
	my $cur = $op->first;

	$cur = $cur->sibling if (($cur->type == 0) && (${$cur->sibling}));

	my ($t, $r) = typeOp($cur, $pad2type, $env, $cv, SCALAR());

	# If the operand has some scalar type, return that scalar
	# type.  Otherwise, return a fresh scalar type.
	if ($t->is(Devel::TypeCheck::Type::K())) {
	    ($realResult, $realReturn) = ($t, $r);
	} else {
	    ($realResult, $realReturn) = ($env->freshKappa, $r);
	}

    } elsif ($t == OP_WANTARRAY()) {

	# Always generate an IV
	($realResult, $realReturn) = ($IV, undef);

    } elsif ($t == OP_AV2ARYLEN()) {
	
	# Infer AV type for operand
	my ($t, $r) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	myUnify($env, $t, $AV);

	# Return IV type
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_SHIFT()     ||
	     $t == OP_POP()) {
	
	# Infer AV type for operand
	my ($t, $r) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	myUnify($env, $t, $AV);

	# Return fresh KAPPA type
	($realResult, $realReturn) = ($env->freshKappa(), $r);

    } elsif ($t == OP_UNSHIFT() ||
	     $t == OP_PUSH()) {

	my ($t, $r) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	myUnify($env, $t, $AV);

	my @returns = ($r);
	for (my $kid = $op->first->sibling; $$kid; $kid = $kid->sibling) {
	    ($t, $r) = typeOp($kid, $pad2type, $env, $cv, LIST());
	    push(@returns, $r) if (defined($r));
	}

	$r = myUnify($env, @returns);

	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_PADSV()) {

	# Make sure it's a scalar value of some sort
	my $pad = $pad2type->get($op->targ, $env);
	myUnify($env, $pad, $env->freshKappa);
	($realResult, $realReturn) = ($pad, undef);

    } elsif ($t == OP_PADAV()) {

	# Make sure it's an AV, just in case
	my $pad = $pad2type->get($op->targ, $env);
	myUnify($env, $pad, $AV);
	($realResult, $realReturn) = ($AV, undef);

    } elsif ($t == OP_PADHV()) {
	
	# Make sure it's an HV, just in case
	my $pad = $pad2type->get($op->targ, $env);
	myUnify($env, $pad, $HV);
	($realResult, $realReturn) = ($HV, undef);

    } elsif ($t == OP_PADANY()) {

	# It's not implemented.  It shouldn't show up.
	die("PADANY not implemented");
	($realResult, $realReturn) = (undef, undef);

    } elsif ($t == OP_SYSTEM()) {

	my ($t, $r) = typeOpChildren_($op, $pad2type, $env, $cv);
	myUnify($env, $t, $PV);
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_PUSHMARK()) {

	# Operators that are completely ignored
	($realResult, $realReturn) = (undef, undef);

    } elsif ($t == OP_REQUIRE()) {
	
	my ($r, $missed) = typeProtoOp($op, $pad2type, $env, $cv, ($env->freshKappa()));
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_CHDIR()  ||
	     $t == OP_CHROOT() ||
	     $t == OP_UNLINK()) {
	
	my ($r, $missed) = typeProto($op, $pad2type, $env, $cv, ($PV));
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_GSBYNAME()) {
	# IV|AV = op(PV [, PV])

	my ($r, $missed) = typeProto($op, $pad2type, $env, $cv, ($PV, $PV));
	($realResult, $realReturn) = (contextPick($context, $IV), $r);
	
    } elsif ($t == OP_GSBYPORT()) {
	# IV|AV = op(IV [, PV])
	
	my ($r, $missed) = typeProto($op, $pad2type, $env, $cv, ($IV, $PV));
	($realResult, $realReturn) = (contextPick($context, $IV), $r);

    } elsif ($t == OP_BACKTICK() ||
	     # get* operands
	     $t == OP_GHBYNAME() ||
	     $t == OP_GPBYNAME() || 
	     $t == OP_GNBYNAME() ||
	     $t == OP_GPWNAM()   ||
	     $t == OP_GGRNAM()) {
	# IV|AV = op(PV)
	
	my ($r, $missed) = typeProto($op, $pad2type, $env, $cv, ($PV));
	($realResult, $realReturn) = (contextPick($context, $IV), $r);

    } elsif ($t == OP_GHBYADDR() || 
	     $t == OP_GNBYADDR()) {
	# IV|AV = op(IV, IV)
	
	my ($r, $missed) = typeProto($op, $pad2type, $env, $cv, ($IV, $IV));
	($realResult, $realReturn) = (contextPick($context, $IV), $r);

    } elsif ($t == OP_GPBYNUMBER() ||
	     $t == OP_GPWUID() ||
	     $t == OP_GGRGID()) {
	# IV|AV = op(IV)
	
	my ($r, $missed) = typeProto($op, $pad2type, $env, $cv, ($IV));
	($realResult, $realReturn) = (contextPick($context, $IV), $r);

    } elsif ($t == OP_GHOSTENT() ||
	     $t == OP_GNETENT() ||
	     $t == OP_GPROTOENT() ||
	     $t == OP_GSERVENT() ||
	     $t == OP_GPWENT() ||
	     $t == OP_GGRENT()) {
	# IV|AV = op()

	($realResult, $realReturn) = (contextPick($context, $IV), undef);
	
    } elsif ($t == OP_EHOSTENT() ||
	     $t == OP_ENETENT() ||
	     $t == OP_EPROTOENT() ||
	     $t == OP_ESERVENT() ||
	     $t == OP_SPWENT() ||
	     $t == OP_EPWENT() ||
	     $t == OP_SGRENT() ||
	     $t == OP_EGRENT()) {
	# IV = op()
	
	($realResult, $realReturn) = ($IV, undef);
	
    } elsif ($t == OP_SHOSTENT() ||
	     $t == OP_SNETENT() ||
	     $t == OP_SPROTOENT() ||
	     $t == OP_SSERVENT()) {
	# IV = op(MKa)

	my ($r, $missed) = typeProto($op, $pad2type, $env, $cv, ($env->freshKappa));
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_FTRREAD() ||
	     $t == OP_FTRWRITE() ||
	     $t == OP_FTREXEC() ||
	     $t == OP_FTEREAD() ||
	     $t == OP_FTEWRITE() ||
	     $t == OP_FTEEXEC() ||
	     $t == OP_FTIS() ||
	     $t == OP_FTEOWNED() ||
	     $t == OP_FTROWNED() ||
	     $t == OP_FTZERO() ||
	     $t == OP_FTSIZE() ||
	     $t == OP_FTMTIME() ||
	     $t == OP_FTATIME() ||
	     $t == OP_FTCTIME() ||
	     $t == OP_FTSOCK() ||
	     $t == OP_FTCHR() ||
	     $t == OP_FTBLK() ||
	     $t == OP_FTFILE() ||
	     $t == OP_FTDIR() ||
	     $t == OP_FTPIPE() ||
	     $t == OP_FTLINK() ||
	     $t == OP_FTSUID() ||
	     $t == OP_FTSGID() ||
	     $t == OP_FTSVTX() ||
	     $t == OP_FTTTY() ||
	     $t == OP_FTTEXT() ||
	     $t == OP_FTBINARY()) {

	# If we're doing it to an IO handle, then this is a PADOP
	# instead of a UNOP, and there aren't really any operands to
	# check.
	my ($t, $r) = (undef, undef);
	if ($op->flags & B::OPf_KIDS) {
	    ($t, $r) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	    myUnify($env, $t, $PV);
	}

	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_STAT() ||
	     $t == OP_LSTAT()) {

	my ($r, $missed) = typeProtoOp($op, $pad2type, $env, $cv, ($PV));
	($realResult, $realReturn) = ($AV, $r);
	
    } elsif ($t == OP_REGCMAYBE() ||
	     $t == OP_REGCRESET() ||
	     $t == OP_REGCOMP() ||
	     $t == OP_QR() ||
	     $t == OP_SCHOP() ||
	     $t == OP_SCHOMP() ||
	     $t == OP_UCFIRST() ||
	     $t == OP_LCFIRST() ||
	     $t == OP_UC() ||
	     $t == OP_LC() ||
	     $t == OP_QUOTEMETA() ||
	     $t == OP_READLINK()) {

	my ($r, $missed) = typeProtoOp($op, $pad2type, $env, $cv, ($PV));
	($realResult, $realReturn) = ($PV, $r);
	
    } elsif ($t == OP_STUDY() ||
	     $t == OP_POS() ||
	     $t == OP_RMDIR()) {

	my ($r, $missed) = typeProtoOp($op, $pad2type, $env, $cv, ($PV));
	($realResult, $realReturn) = ($IV, $r);
	
    } elsif ($t == OP_SRAND() ||
	     $t == OP_ALARM()) {

	my ($r, $missed) = typeProtoOp($op, $pad2type, $env, $cv, ($IV));
	($realResult, $realReturn) = ($IV, $r);
	
    } elsif ($t == OP_CHR()) {

	my ($r, $missed) = typeProtoOp($op, $pad2type, $env, $cv, ($IV));
	($realResult, $realReturn) = ($PV, $r);
	
    } elsif ($t == OP_LOCALTIME() ||
	     $t == OP_GMTIME()) {

	my ($r, $missed) = typeProtoOp($op, $pad2type, $env, $cv, ($IV));
	($realResult, $realReturn) = (contextPick($context, $PV), $r);

    } elsif ($t == OP_DELETE() ||
	     $t == OP_EXISTS()) {

	my ($t, $r) = typeOpChildren($op, $pad2type, $env, $cv);
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_FORK() ||
	     $t == OP_WAIT() ||
	     $t == OP_TIME()) {

    } elsif ($t == OP_TMS()) {

	($realResult, $realReturn) = (contextPick($context, $DV), undef);

    } elsif ($t == OP_TRANS()) {

	($realResult, $realReturn) = ($PV, undef);

    } elsif ($t == OP_GLOB() ||
	     $t == OP_READLINE() ||
	     $t == OP_RCATLINE()) {

	my ($t, $r) = typeOpChildren($op, $pad2type, $env, $cv);
	($realResult, $realReturn) = ($env->fresh, $r);
	
    } elsif ($t == OP_UNDEF()) {

	# Can't infer type here, since undef may legitimately be used
	# to vacate variables of any sort.  Still, we should typecheck
	# the argument, if there is one.
	my ($t, $r) = (undef, undef);
	if ($op->flags & B::OPf_KIDS()) {
	    ($t, $r) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	}

	# Generate a type of ref to var
	($realResult, $realReturn) = ($env->freshRho(), $r);

    } elsif ($t == OP_GOTO() ||
	     $t == OP_DUMP()) {

	# Make sure the argument to goto (if there is one) is at least
	# internally consistent.
	my ($t, $r) = (undef, undef);
	if ($op->flags & B::OPf_KIDS()) {
	    ($t, $r) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	}	

	($realResult, $realReturn) = (undef, $r);
	
    } elsif ($t == OP_UNSTACK() ||
	     $t == OP_LAST()    ||
	     $t == OP_NEXT()    ||
	     $t == OP_REDO()) {

	($realResult, $realReturn) = (undef, undef);

    } elsif ($t == OP_DIE() ||
	     $t == OP_WARN()) {

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($ANY));
	($realResult, $realReturn) = (undef, myUnify($env, $r));

    } elsif ($t == OP_EXIT()) {

	my ($t, $r);
	if ($op->flags & B::OPf_KIDS()) {
	    ($t, $r) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	}

	($realResult, $realReturn) = (undef, $r);

    } elsif ($t == OP_RETURN()) {
	
	my ($t, $r) = typeOpChildren($op, $pad2type, $env, $cv);
	($realResult, $realReturn) = (undef, $t);

    } elsif ($t == OP_METHOD() ||
	     $t == OP_METHOD_NAMED()) {

	($realResult, $realReturn) = ($env->fresh, undef);

    } elsif ($t == OP_GREPWHILE() ||
	     $t == OP_MAPWHILE() ||
	     $t == OP_FLOP()) {
	
	my ($t, $r) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	($realResult, $realReturn) = (contextPick($context, $env->freshKappa), $r);

    } elsif ($t == OP_FLIP() ||
	     $t == OP_CUSTOM()) {
	
	my ($t, $r) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	($realResult, $realReturn) = ($env->fresh, $r);

    } elsif ($t == OP_DEFINED() ||
	     $t == OP_UNTIE() ||
	     $t == OP_LOCK()) {

	my ($t, $r) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_CHOP() ||
	     $t == OP_CHOMP()) {

	my ($t, $r) = typeOp($op->first, $pad2type, $env, $cv, LIST());
	($realResult, $realReturn) = ($AV, $r);

    } elsif ($t == OP_SORT() ||
	     $t == OP_REVERSE()) {

	my ($t, $r) = typeOpChildren($op, $pad2type, $env, $cv);
	($realResult, $realReturn) = ($AV, $r);
	
    } elsif ($t == OP_EXEC() ||
	     $t == OP_KILL() ||
	     $t == OP_SYSCALL()) {
	
	my ($t, $r) = typeOpChildren($op, $pad2type, $env, $cv);
	($realResult, $realReturn) = ($IV, $r);
	
    } elsif ($t == OP_SETPRIORITY() ||
	     $t == OP_SHMGET() ||
	     $t == OP_SHMCTL() ||
	     $t == OP_MSGCTL() ||
	     $t == OP_SEMGET()){

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($IV, $IV, $IV));
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_VALUES() ||
	     $t == OP_KEYS()) {

	my ($r, $missing) = typeProtoOp($op, $pad2type, $env, $cv, ($HV));
	($realResult, $realReturn) = ($AV, $r);

    } elsif ($t == OP_EACH()) {

	my ($r, $missing) = typeProtoOp($op, $pad2type, $env, $cv, ($HV));
	($realResult, $realReturn) = ($env->freshKappa, $r);

    } elsif ($t == OP_LSLICE()) {

	my ($r, $missing) = typeProtoOp($op, $pad2type, $env, $cv, ($AV, $AV));
	
	# Make it all right to use LSLICE in a scalar context
	($realResult, $realReturn) = (contextPick($context, $env->freshKappa), $r);

    } elsif ($t == OP_TIED()) {

	my ($r, $missing) = typeProtoOp($op, $pad2type, $env, $cv, ($env->fresh));
	($realResult, $realReturn) = ($env->fresh, $r);

    } elsif ($t == OP_REPEAT()) {
	my ($t, $r, $t0, $r0);

	my @rets;

	# List repeat
	if ($op->private & 64) {
	    ($t, $r) = typeOp($op->first, $pad2type, $env, $cv, LIST());

	    @rets = ($r);
	    if (${$op->last}) {
		($t0, $r0) = typeOp($op->last, $pad2type, $env, $cv, SCALAR());
		myUnify($env, $t0, $IV);
		push(@rets, $r0) if ($r0);
	    }

	    ($realResult, $realReturn) = (myUnify($env, $t, $AV), myUnify($env, @rets));
	} else {
	    # PV repeat
	    ($t, $r) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	    myUnify($env, $t, $PV);
	    push(@rets, $r0) if ($r);

	    ($t0, $r0) = typeOp($op->last, $pad2type, $env, $cv, SCALAR());
	    myUnify($env, $t0, $IV);
	    push(@rets, $r0) if ($r0);
	    verbose("baz");

	    ($realResult, $realReturn) = ($PV, myUnify($env, @rets));
	}

    } elsif ($t == OP_CALLER()) {

	my ($r, $missing) = typeProtoOp($op, $pad2type, $env, $cv, ($IV));
	($realResult, $realReturn) = (contextPick($context, $PV), $r);

    } elsif ($t == OP_RANGE()) {

	my ($r, $missing) = typeProtoOp($op, $pad2type, $env, $cv, ($IV, $IV));
	($realResult, $realReturn) = ($AV, $r);

    } elsif ($t == OP_RESET()) {

	my ($r, $missing) = typeProtoOp($op, $pad2type, $env, $cv, ($PV));
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_CLOSE() ||
	     $t == OP_FILENO() ||
	     $t == OP_EOF() ||
	     $t == OP_TELL() ||
	     $t == OP_TELLDIR() ||
	     $t == OP_REWINDDIR() ||
	     $t == OP_CLOSEDIR()) {
	
	my ($r, $missing) = typeProtoOp($op, $pad2type, $env, $cv, ($env->freshEta));
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_UMASK()) {

	my ($r, $missing) = typeProtoOp($op, $pad2type, $env, $cv, ($PV));
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_DBMCLOSE()) {

	my ($r, $missing) = typeProtoOp($op, $pad2type, $env, $cv, ($HV));
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_MKDIR()) {

	my ($r, $missing) = typeProtoOp($op, $pad2type, $env, $cv, ($PV, $IV));
	($realResult, $realReturn) = ($IV, $r);	

    } elsif ($t == OP_READDIR()) {
	
	my ($r, $missing) = typeProtoOp($op, $pad2type, $env, $cv, ($env->freshEta));
	($realResult, $realReturn) = (contextPick($context, $PV), $r);

    } elsif ($t == OP_INDEX() ||
	     $t == OP_RINDEX()) {

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($PV, $PV, $IV));
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_RENAME() ||
	     $t == OP_LINK() ||
	     $t == OP_SYMLINK()) {

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($PV, $PV));
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_CRYPT()) {

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($PV, $PV));
	($realResult, $realReturn) = ($PV, $r);

    } elsif ($t == OP_FLOCK() ||
	     $t == OP_BIND() ||
	     $t == OP_CONNECT() ||
	     $t == OP_SHUTDOWN() ||
	     $t == OP_SEEKDIR()) {

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($env->freshEta, $IV));
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_SYSSEEK() ||
	     $t == OP_SEEK() ||
	     $t == OP_FCNTL() ||
	     $t == OP_IOCTL() ||
	     $t == OP_GSOCKOPT()) {

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($env->freshEta, $IV, $IV));
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_SYSREAD() ||
	     $t == OP_SYSWRITE() ||
	     $t == OP_READ() ||
	     $t == OP_SEND() ||
	     $t == OP_RECV()) {

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($env->freshEta, $env->freshKappa, $IV, $IV));
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_PIPE_OP() ||
	     $t == OP_ACCEPT()) {

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($env->freshEta, $env->freshEta));
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_BINMODE() ||
	     $t == OP_OPEN_DIR()) {

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($env->freshEta, $PV));
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_SOCKET()) {

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($env->freshEta, $IV, $IV, $IV));
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_OPEN() ||
	     $t == OP_UTIME()) {

	# This operator is way too overloaded:
	# OP_OPEN         IV = fop(MKPMH(a, ...) [, PV [, PV|MKPMH(b, ...) [, ...]]]) | op()

	my ($t, $r) = typeOpChildren($op, $pad2type, $env, $cv);
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_SYSOPEN()) {

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($env->freshEta, $PV, $IV, $IV));
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_SOCKPAIR()) {

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($env->freshEta, $env->freshEta, $IV ,$IV, $IV));
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_SSOCKOPT()) {

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($env->freshEta, $IV, $IV, $env->freshKappa));
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_SPRINTF() ||
	     $t == OP_FORMLINE()) {

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($PV, $ANY));
	($realResult, $realReturn) = ($PV, $r);

    } elsif ($t == OP_PACK()) {

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($PV, $ANY));
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_UNPACK()) {
	
	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($PV, $IV));
	($realResult, $realReturn) = ($AV, $r);

    } elsif ($t == OP_MSGGET() ||
	     $t == OP_SEMOP()) {

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($IV, $IV));
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_SHMREAD() ||
	     $t == OP_SHMWRITE()) {

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($IV, $PV, $IV, $IV));
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_MSGSND()) {

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($IV, $PV, $IV, $IV, $IV));
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_SEMCTL()) {

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($IV, $IV, $IV, $IV));
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_MSGRCV()) {

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($IV, $PV, $IV));
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_TRUNCATE()) {

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($PV, $IV));
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_CHOWN()) {

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($IV, $IV, $ANY));
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_CHMOD()) {

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($IV, $ANY));
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_PRTF()) {

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($ANY));
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_SSELECT()) {

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($IV, $IV, $IV, $DV));
	($realResult, $realReturn) = (contextPick($context, $IV), $r);

    } elsif ($t == OP_SELECT()) {

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($env->fresh));
	($realResult, $realReturn) = ($PV, $r);

    } elsif ($t == OP_TIE()) {

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($env->fresh, $PV, $ANY));
	($realResult, $realReturn) = (undef, $r);

    } elsif ($t == OP_SSELECT()) {

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($IV, $IV, $IV, $DV));
	($realResult, $realReturn) = (contextPick($context, $AV), $r);

    } elsif ($t == OP_STRINGIFY()) {

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($env->freshKappa));
	($realResult, $realReturn) = ($PV, $r);

    } elsif ($t == OP_VEC()) {

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($env->freshKappa, $IV, $IV));
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_ASLICE()) {

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($AV, $AV));
	($realResult, $realReturn) = ($AV, $r);

    } elsif ($t == OP_HSLICE()) {

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($AV, $HV));
	($realResult, $realReturn) = ($AV, $r);

    } elsif ($t == OP_ANONHASH()) {

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($ANY));
	($realResult, $realReturn) = ($HV, $r);

    } elsif ($t == OP_SPLICE()) {

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($AV, $IV, $IV, $AV));
	($realResult, $realReturn) = ($AV, $r);

    } elsif ($t == OP_GREPSTART() ||
	     $t == OP_MAPSTART()) {

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($env->fresh, $AV));
	($realResult, $realReturn) = ($env->fresh, $r);

    } elsif ($t == OP_DBMOPEN()) {

	my ($r, $missing) = typeProto($op, $pad2type, $env, $cv, ($HV, $PV, $IV));
	($realResult, $realReturn) = ($IV, $r);

    } elsif ($t == OP_LENGTH()) {

	my ($t, $r) = typeOp($op->first, $pad2type, $env, $cv, SCALAR());
	myUnify($env, $t, $PV);
	($realResult, $realReturn) = ($IV, $r);

    } else {

	# OP_LEAVEEVAL() is here implicitly
	# OP_THREADSV() is here implicitly
	
	warn("Typing for OP ", $t, " is unimplemented\n");

	# Try to do something sane depending on context
	if ($context == SCALAR()) {
	    ($realResult, $realReturn) = ($env->fresh, undef);
	} else {
	    ($realResult, $realReturn) = ($AV, undef);
	}

    }

    verbose(" " x $depth, "} = ", $realResult?$env->find($realResult)->str($env):"void");
    $depth -= $depthIncrement;
    return ($realResult, $realReturn);
}

sub typecheck {
    my ($op, $cv, $env) = @_;

    my $pad2type = Devel::TypeCheck::Pad2type->new();

    my ($resType, $retType) = typeOp($op, $pad2type, $env, $cv, SCALAR());

    $resType = $resType?($env->find($resType)):undef;
    $retType = $retType?($env->find($retType)):undef;

    $pad2type->print(\*STDOUT, $cv, $env);

    return ($resType, $retType);
}

sub callback {
    my %main;

    for my $name (@cvnames) {
	# From B::Concise::compile
	$name = "main::" . $name unless $name =~ /::/;

	no strict 'refs';
	die "err: unknown function ($name)\n"
	    unless *{$name}{CODE};
	my $ref = \&$name;

	# &From B::Concise::concise_subref
	my $cv = B::svref_2object($ref);
	die "err: not a coderef: $ref\n" unless ref $cv eq 'B::CV';#CODE';

	my $op = $cv->ROOT;

	my %cur;
	$cur{'name'} = $name;
	$cur{'op'} = $op;
	$cur{'cv'} = $cv;
	push(@roots, \%cur);
    }

    if ($mainRoot) {
	$main{'name'} = 'main::MAIN';
	$main{'op'} = B::main_root();
	$main{'cv'} = B::main_cv();
	push(@roots, \%main);
    }

    $glob2type = Devel::TypeCheck::Glob2type->new();

    my $env = Devel::TypeCheck::Environment->new();

    print("Type checking CVs:\n");
    for my $i (@roots) {
#	next unless (blessed($i));
	print("  $i->{'name'}\n");
	my ($t, $r) = typecheck($i->{'op'}, $i->{'cv'}, $env);
	if (defined($t)) {
	    print("  Result type of $i->{'name'} is ", $t->str($env), "\n");
	} else {
	    print("  Result type of $i->{'name'} is undefined\n");
	}
	if (defined($r)) {
	    print("  Return type of $i->{'name'} is ", $r->str($env), "\n");
	} else {
	    print("  Return type of $i->{'name'} is undefined\n");
	}
	print("\n");
    }

    my ($i, $t);


    print STDOUT ("Global Symbol Table Types:\nName                Type\n------------------------------------------------------------------------------\n");

    format STDOUT =
@<<<<<<<<<<<<<<<<<< @<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
$i,                 $t
.
    
    for $i (sort($glob2type->symbols)) {
        $t = $glob2type->get($i)->str($env);
        write STDOUT;
    }

    print("Total opcodes processed: $opcodes\n");
}

1;