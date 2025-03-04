#=====================================================================
# LedgerSMB
# Small Medium Business Accounting software
# http://www.ledgersmb.org/
#
# Copyright (C) 2006
# This work contains copyrighted information from a number of sources all used
# with permission.
#
# This file contains source code included with or based on SQL-Ledger which
# is Copyright Dieter Simader and DWS Systems Inc. 2000-2005 and licensed
# under the GNU General Public License version 2 or, at your option, any later
# version.  For a full list including contact information of contributors,
# maintainers, and copyright holders, see the CONTRIBUTORS file.
#
# Original Copyright Notice from SQL-Ledger 2.6.17 (before the fork):
# Copyright (C) 2001
#
#  Author: DWS Systems Inc.
#     Web: http://www.sql-ledger.org
#
#  Contributors:
#
#======================================================================
#
# This file has undergone  whitespace cleanup
#
#======================================================================
#
# Order entry module
# Quotation
#
#======================================================================

package OE;
use LedgerSMB::Tax;
use LedgerSMB::Sysconfig;

my $logger = Log::Log4perl->get_logger('OE');
=over

=item get_files

Returns a list of files associated with the existing transaction.  This is 
provisional, and will change for 1.4 as the GL transaction functionality is 
                  {ref_key => $self->{id}, file_class => 2}
rewritten

=cut

sub get_files {
     my ($self, $form, $locale) = @_;
     return if !$form->{id};
     my $file = LedgerSMB::File->new();
     $file->new_dbobject({base => $form, locale => $locale});
     @{$form->{files}} = $file->list({ref_key => $form->{id}, file_class => 2});
     @{$form->{file_links}} = $file->list_links(
                  {ref_key => $form->{id}, file_class => 2}
     );

}

=get_type 

Sets the type field for an existing order or quotation

=cut

sub get_type {
    my ($self, $form) = @_;
    my $dbh = $form->{dbh};
    my @types = qw(null sales_order purchase_order sales_quotation 
                   request_quotation);
    my $sth = $dbh->prepare('select oe_class_id from oe where id = ?');
    $sth->execute($form->{id});
    my ($class) = $sth->fetchrow_array;
    $form->{type} = $types[$class];
    $sth->finish;
}

sub transactions {
    my ( $self, $myconfig, $form ) = @_;

    # connect to database
    my $dbh = $form->{dbh};

    my $query;
    my $null;
    my $var;
    my $ordnumber = 'ordnumber';
    my $quotation = '0';
    my $department;

    my $rate = ( $form->{vc} eq 'customer' ) ? 'buy' : 'sell';

    ( $form->{transdatefrom}, $form->{transdateto} ) =
      $form->from_to( $form->{year}, $form->{month}, $form->{interval} )
      if $form->{year} && $form->{month};

    if ( $form->{type} =~ /_quotation$/ ) {
        $quotation = '1';
        $ordnumber = 'quonumber';
    }

    my $number  = $form->like( lc $form->{$ordnumber} );
    my $name    = $form->like( lc $form->{ $form->{vc} } );
    my @dptargs = ();

    for (qw(department employee)) {
        if ( $form->{$_} ) {
            ( $null, $var ) = split /--/, $form->{$_};
            $department .= " AND o.${_}_id = ?";
            push @dptargs, $var;
        }
    }

    if ( $form->{vc} ne 'customer' ) {    # Sanitize $form->{vc}
        $form->{vc} = 'vendor';
    }
    $query = qq|
		SELECT o.id, o.ordnumber, o.transdate, o.reqdate,
			o.amount, c.legal_name AS name, o.netamount, o.entity_credit_account AS $form->{vc}_id,
			ex.$rate AS exchangerate, o.closed, o.quonumber, 
			o.shippingpoint, o.shipvia,
			pe.first_name \|\| ' ' \|\| pe.last_name AS employee, 
			pm.first_name \|\| ' ' \|\| pm.last_name AS manager, 
			o.curr, o.ponumber, ct.meta_number, c.entity_id
		FROM oe o
		JOIN entity_credit_account ct ON (o.entity_credit_account = ct.id)
		JOIN company c ON (c.entity_id = ct.entity_id)
		LEFT JOIN person pe ON (o.person_id = pe.id)
		LEFT JOIN entity_employee e ON (pe.entity_id = e.entity_id)
		LEFT JOIN person pm ON (e.manager_id = pm.id)
		LEFT JOIN entity_employee m ON (pm.entity_id = m.entity_id)
		LEFT JOIN exchangerate ex 
			ON (ex.curr = o.curr AND ex.transdate = o.transdate)
		WHERE o.quotation = ?
                      AND o.oe_class_id = ?
		$department|;

    my @queryargs = @dptargs;
    unshift @queryargs, $form->{oe_class_id};
    unshift @queryargs, $quotation;

    my %ordinal = (
        id        => 1,
        ordnumber => 2,
        transdate => 3,
        reqdate   => 4,
        name      => 6,
        quonumber => 11,
        shipvia   => 13,
        employee  => 14,
        manager   => 15,
        curr      => 16,
        ponumber  => 17
    );

    my @a = ( 'transdate', $ordnumber, 'name' );
    push @a, "employee" if $form->{l_employee};
    if ( $form->{type} !~ /(ship|receive)_order/ ) {
        push @a, "manager" if $form->{l_manager};
    }
    my $sortorder = $form->sort_order( \@a, \%ordinal );

    # build query if type eq (ship|receive)_order
    if ( $form->{type} =~ /(ship|receive)_order/ ) {

        my ( $warehouse, $warehouse_id ) = split /--/, $form->{warehouse};

        #HV alias company.ct changed to company.c
        $query = qq|
			SELECT DISTINCT o.id, o.ordnumber, o.transdate,
				o.reqdate, o.amount, c.legal_name, o.netamount, 
				o.entity_credit_account as $form->{vc}_id, ex.$rate AS exchangerate,
		 		o.closed, o.quonumber, o.shippingpoint, 
				o.shipvia, ee.name AS employee, o.curr, 
				o.ponumber
			FROM oe o
			JOIN entity_credit_account eca  
                             ON (o.entity_credit_account = eca.id)
                        JOIN company c ON eca.entity_id = c.entity_id
			JOIN orderitems oi ON (oi.trans_id = o.id)
			JOIN parts p ON (p.id = oi.parts_id)|;

        if ( $warehouse_id && $form->{type} eq 'ship_order' ) {
            $query .= qq|
				JOIN inventory i ON (oi.parts_id = i.parts_id)
				|;
        }

        $query .= qq|
                        LEFT JOIN person per ON per.id = o.person_id
			LEFT JOIN entity_employee e ON (per.entity_id = e.entity_id)
			LEFT JOIN entity ee ON (e.entity_id = ee.id)
			LEFT JOIN exchangerate ex 
				ON (ex.curr = o.curr 
					AND ex.transdate = o.transdate)
			WHERE o.quotation = '0'
			AND (p.inventory_accno_id > 0 OR p.assembly = '1')
			AND oi.qty != oi.ship
			$department|;
        @queryargs = @dptargs;    #reset @queryargs

        if ( $warehouse_id && $form->{type} eq 'ship_order' ) {
            $query .= qq| 
				AND i.warehouse_id = ?
				AND ( 
					SELECT SUM(i.qty)
					FROM inventory i
					WHERE oi.parts_id = i.parts_id
					AND i.warehouse_id = ? 
				) > 0|;
            push( @queryargs, $warehouse_id, $warehouse_id );
        }

    }

    if ( $form->{"$form->{vc}_id"} ) {
        $query .= qq| AND o.$form->{vc}_id = $form->{"$form->{vc}_id"}|;
    }
    elsif ( $form->{ $form->{vc} } ne "" ) {
        $query .= " AND lower(c.legal_name) LIKE ?";
        push @queryargs, $name;
    }

    if ( $form->{$ordnumber} ne "" ) {
	$ordnumber = ($ordnumber eq 'ordnumber') ? 'ordnumber' : 'quonumber';
        $query .= " AND lower($ordnumber) LIKE ?";
        push @queryargs, $number;
        $form->{open}   = 1;
        $form->{closed} = 1;
    }
    if ( $form->{ponumber} ne "" ) {
        $query .= " AND lower(ponumber) LIKE '%' || lower(?) || '%'";
        push @queryargs, $form->{ponumber};
    }

    if ( !$form->{open} && !$form->{closed} ) {
        $query .= " AND o.id = 0";
    }
    elsif ( !( $form->{open} && $form->{closed} ) ) {
        $query .=
          ( $form->{open} ) ? " AND o.closed = '0'" : " AND o.closed = '1'";
    }

    if ( $form->{shipvia} ne "" ) {
        $var = $form->like( lc $form->{shipvia} );
        $query .= " AND lower(o.shipvia) LIKE ?";
        push @queryargs, $var;
    }

    if ( $form->{description} ne "" ) {
        $var = $dbh->quote($form->like( lc $form->{description} ));
        $query .= " AND o.id IN (SELECT DISTINCT trans_id
                             FROM orderitems
			     WHERE lower(description) LIKE $var)";
    }

    if ( $form->{transdatefrom} ) {
        $query .= " AND o.transdate >= ?";
        push @queryargs, $form->{transdatefrom};
    }
    if ( $form->{transdateto} ) {
        $query .= " AND o.transdate <= ?";
        push @queryargs, $form->{transdateto};
    }

    $query .= " ORDER by $sortorder";

    my $sth = $dbh->prepare($query);
    $sth->execute(@queryargs) || $form->dberror($query);

    my %oid = ();
    while ( my $ref = $sth->fetchrow_hashref(NAME_lc) ) {
	$form->db_parse_numeric(sth=>$sth, hashref=>$ref);
        $ref->{exchangerate} = 1 unless $ref->{exchangerate};
        if ( $ref->{id} != $oid{id}{ $ref->{id} } ) {
            push @{ $form->{OE} }, $ref;
            $oid{vc}{ $ref->{curr} }{ $ref->{"$form->{vc}_id"} }++;
        }
        $oid{id}{ $ref->{id} } = $ref->{id};
    }
    $sth->finish;

    $dbh->commit;

    if ( $form->{type} =~ /^consolidate_/ ) {
        @a = ();
        foreach $ref ( @{ $form->{OE} } ) {
            push @a, $ref
              if $oid{vc}{ $ref->{curr} }{ $ref->{"$form->{vc}_id"} } > 1;
        }

        @{ $form->{OE} } = @a;
    }

}

sub save {
    my ( $self, $myconfig, $form ) = @_;
  
    $form->db_prepare_vars(
        "quonumber", "transdate",     "vendor_id",     "entity_id",
        "reqdate",   "taxincluded",   "shippingpoint", "shipvia",
        "currency",  "department_id", "employee_id",   "language_code",
        "ponumber",  "terms"
    );
    # connect to database, turn off autocommit
    my $dbh = $form->{dbh};
    my @queryargs;
    my $quotation;
    my $ordnumber;
    my $numberfld;
    my $class_id;
    $form->{vc} = ( $form->{vc} eq 'customer' ) ? 'customer' : 'vendor';
    if ( $form->{type} =~ /_order$/ ) {
        $quotation = "0";
        $ordnumber = "ordnumber";
	if ($form->{vc} eq 'customer'){
             $numberfld = "sonumber";
             $class_id = 1;
        } else {
             $numberfld = "ponumber";
             $class_id = 2;
        }
    }
    else {
        $quotation = "1";
        $ordnumber = "quonumber";
        if ( $form->{vc} eq 'customer' ) {
	    $numberfld = "sqnumber";
	    $class_id = 3;
	} else {
	    $numberfld = "rfqnumber";
	    $class_id = 4;
	}
    }
    $form->{"$ordnumber"} =
      $form->update_defaults( $myconfig, $numberfld, $dbh )
      unless $form->{"$ordnumber"};



    my $query;
    my $sth;
    my $null;
    my $exchangerate = 0;

    ( $null, $form->{employee_id} ) = split /--/, $form->{employee};
    if ( !$form->{employee_id} ) {
        ( $form->{employee}, $form->{employee_id} ) = $form->get_employee($dbh);
        $form->{employee} = "$form->{employee}--$form->{employee_id}";
    }

    my $ml = ( $form->{type} eq 'sales_order' ) ? 1 : -1;

    $query = qq|
		SELECT p.assembly, p.project_id
		FROM parts p WHERE p.id = ?|;
    my $pth = $dbh->prepare($query) || $form->dberror($query);

    if ( $form->{id} ) {
        
        $query = qq|SELECT id FROM oe WHERE id = $form->{id}|;

        if ( $dbh->selectrow_array($query) ) {
            &adj_onhand( $dbh, $form, $ml )
              if $form->{type} =~ /_order$/;

            $query = qq|DELETE FROM orderitems WHERE trans_id = ?|;
            $sth   = $dbh->prepare($query);
            $sth->execute( $form->{id} ) || $form->dberror($query);

            $query = qq|DELETE FROM new_shipto WHERE trans_id = ?|;
            $sth   = $dbh->prepare($query);
            $sth->execute( $form->{id} ) || $form->dberror($query);

        }
        else {    # id is not in the database
            delete $form->{id};
        }

    }
    my $did_insert = 0;
    if ( !$form->{id} ) {
        $query = qq|SELECT nextval('oe_id_seq')|;
        $sth   = $dbh->prepare($query);
        $sth->execute || $form->dberror($query);
        ( $form->{id} ) = $sth->fetchrow_array;
        $sth->finish;

        my $uid = localtime;
        $uid .= "$$";
        if ( !$form->{reqdate} ) {
            $form->{reqdate} = undef;
        }
        if ( !$form->{transdate} ) {
            $form->{transdate} = "now";
        }

        if ( ( $form->{closed} ne 't' ) and ( $form->{closed} ne "1" ) ) {
            $form->{closed} = 'f';
        }

        # $form->{id} is safe because it is only pulled *from* the db.
        $query = qq|
			INSERT INTO oe 
				(id, ordnumber, quonumber, transdate, 
				reqdate, shippingpoint, shipvia,
				notes, intnotes, curr, closed, department_id,
				person_id, language_code, ponumber, terms,
				quotation, oe_class_id, entity_credit_account)
			VALUES 
				($form->{id}, ?, ?, ?,
				?, ?, ?,
				?, ?, ?, ?, ?,
				?, ?, ?, ?,
				?, ?, ?)|;
        @queryargs = (
            $form->{ordnumber},     $form->{quonumber},
            $form->{transdate},     $form->{reqdate},
            $form->{shippingpoint}, $form->{shipvia},
            $form->{notes},         $form->{intnotes},
            $form->{currency},      $form->{closed},
            $form->{department_id}, $form->{person_id},
            $form->{language_code}, $form->{ponumber},
            $form->{terms},         $quotation, $class_id, $form->{"$form->{vc}_id"}
        );
        $sth = $dbh->prepare($query);
        $sth->execute(@queryargs) || $form->dberror($query);
        $sth->finish;

        @queries = $form->run_custom_queries( 'oe', 'INSERT' );

    }

    my $amount;
    my $linetotal;
    my $discount;
    my $project_id;
    my $taxrate;
    my $taxamount;
    my $fxsellprice;
    my %taxbase;
    my @taxaccounts;
    my %taxaccounts;
    my $netamount = 0;

    my $rowcount = $form->{rowcount};
    for my $i ( 1 .. $rowcount ) {
        $form->{"ship_$i"} = 0 unless $form->{"ship_$i"};
        $form->db_prepare_vars( "orderitems_id_$i", "id_$i", "description_$i",
            "project_id_$i" );

        for (qw(qty ship)) {
            $form->{"${_}_$i"} =
              $form->parse_amount( $myconfig, $form->{"${_}_$i"} );
        }

        $form->{"discount_$i"} =
          $form->parse_amount( $myconfig, $form->{"discount_$i"} ) / 100;

        $form->{"sellprice_$i"} =
          $form->parse_amount( $myconfig, $form->{"sellprice_$i"} );

        if ( $form->{"qty_$i"} ) {
            $pth->execute( $form->{"id_$i"} );
            $ref = $pth->fetchrow_hashref(NAME_lc);
            for ( keys %$ref ) { $form->{"${_}_$i"} = $ref->{$_} }
            $pth->finish;

            $fxsellprice = $form->{"sellprice_$i"};

            my ($dec) = ( $form->{"sellprice_$i"} =~ /\.(\d+)/ );
            $dec = length $dec;
            my $decimalplaces = ( $dec > 2 ) ? $dec : 2;

            $discount =
              $form->round_amount(
                $form->{"sellprice_$i"} * $form->{"discount_$i"},
                $decimalplaces );
            $form->{"sellprice_$i"} =
              $form->round_amount( $form->{"sellprice_$i"} - $discount,
                $decimalplaces );

            $linetotal =
              $form->round_amount( $form->{"sellprice_$i"} * $form->{"qty_$i"},
                2 );

            @taxaccounts = Tax::init_taxes( $form, $form->{"taxaccounts_$i"},
                $form->{taxaccounts} );
            if ( $form->{taxincluded} ) {
                $taxamount =
                  Tax::calculate_taxes( \@taxaccounts, $form, $linetotal, 1 );
                $form->{"sellprice_$i"} =
                  Tax::extract_taxes( \@taxaccounts, $form,
                    $form->{"sellprice_$i"} );
                $taxbase =
                  Tax::extract_taxes( \@taxaccounts, $form, $linetotal );
            }
            else {
                $taxamount =
                  Tax::apply_taxes( \@taxaccounts, $form, $linetotal );
                $taxbase = $linetotal;
            }

            if ( @taxaccounts && $form->round_amount( $taxamount, 2 ) == 0 ) {
                if ( $form->{taxincluded} ) {
                    foreach $item (@taxaccounts) {
                        $taxamount = $form->round_amount( $item->value, 2 );
                        $taxaccounts{ $item->account } += $taxamount;
                        $taxdiff                       += $taxamount;
                        $taxbase{ $item->account }     += $taxbase;
                    }
                    $taxaccounts{ $taxaccounts[0]->account } += $taxdiff;
                }
                else {
                    foreach $item (@taxaccounts) {
                        $taxaccounts{ $item->account } += $item->value;
                        $taxbase{ $item->account }     += $taxbase;
                    }
                }
            }
            else {
                foreach $item (@taxaccounts) {
                    $taxaccounts{ $item->account } += $item->value;
                    $taxbase{ $item->account }     += $taxbase;
                }
            }

            $netamount += $form->{"sellprice_$i"} * $form->{"qty_$i"};

            if ( $form->{"projectnumber_$i"} ne "" ) {
                ( $null, $project_id ) = split /--/,
                  $form->{"projectnumber_$i"};
            }
            $project_id = $form->{"project_id_$i"}
              if $form->{"project_id_$i"};

            if ( !$form->{"reqdate_$i"} ) {
                $form->{"reqdate_$i"} = undef;
            }

            @queryargs = ();

            # save detail record in orderitems table
            $query = qq|INSERT INTO orderitems (
		          trans_id, parts_id, description, qty, sellprice,
		          discount, unit, reqdate, project_id, ship, 
		          serialnumber, notes, precision)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)|;
            $sth = $dbh->prepare($query);
            push( @queryargs,
                $form->{id},                $form->{"id_$i"},
                $form->{"description_$i"},  $form->{"qty_$i"},
                $fxsellprice,               $form->{"discount_$i"},
                $form->{"unit_$i"},         $form->{"reqdate_$i"},
                $project_id,                $form->{"ship_$i"},
                $form->{"serialnumber_$i"}, $form->{"notes_$i"},
                $form->{"precision_$i"}
            );
            $sth->execute(@queryargs) || $form->dberror($query);
	    $dbh->commit;
            $form->{"sellprice_$i"} = $fxsellprice;
        }
        $form->{"discount_$i"} *= 100;
 
    }

    # set values which could be empty
    for (qw(entity_id taxincluded closed quotation)) {
        $form->{$_} *= 1;
    }

    # add up the tax
    my $tax = 0;
    for ( keys %taxaccounts ) { $tax += $taxaccounts{$_} }

    $amount = $form->round_amount( $netamount + $tax, 2 );
    $netamount = $form->round_amount( $netamount, 2 );

    if ( $form->{currency} eq $form->{defaultcurrency} ) {
        $form->{exchangerate} = 1;
    }
    else {
        $exchangerate =
          $form->check_exchangerate( $myconfig, $form->{currency},
            $form->{transdate},
            ( $form->{vc} eq 'customer' ) ? 'buy' : 'sell' );
    }

    $form->{exchangerate} =
      ($exchangerate)
      ? $exchangerate
      : $form->parse_amount( $myconfig, $form->{exchangerate} );

    ( $null, $form->{department_id} ) = split( /--/, $form->{department} );

    for (qw(department_id terms)) { $form->{$_} *= 1 }

    if ($did_insert) {
        $query = qq|
			UPDATE oe SET 
				amount = ?,
				netamount = ?,
				taxincluded = ?
			WHERE id = ?|;
        @queryargs = ( $amount, $netamount, $form->{taxincluded}, $form->{id} ); 
    }
    else {

        # save OE record
        $query = qq|
			UPDATE oe set
				ordnumber = ?, 
				quonumber = ?,
				transdate = ?,
				amount = ?, 
				netamount = ?,
				reqdate = ?,
				taxincluded = ?, 
				shippingpoint = ?, 
				shipvia = ?, 
				notes = ?, 
				intnotes = ?, 
				curr = ?, 
				closed = ?, 
				quotation = ?, 
				department_id = ?, 
				person_id = ?, 
				language_code = ?, 
				ponumber = ?, 
				terms = ?
			WHERE id = ?|;

        if ( !$form->{reqdate} ) {
            $form->{reqdate} = undef;
        }

        @queryargs = (
            $form->{ordnumber},     $form->{quonumber},
            $form->{transdate},     $amount,
            $netamount,             $form->{reqdate},
            $form->{taxincluded},   $form->{shippingpoint},
            $form->{shipvia},       $form->{notes},
            $form->{intnotes},      $form->{currency},
            $form->{closed},        $quotation,
            $form->{department_id}, $form->{person_id},
            $form->{language_code}, $form->{ponumber},
            $form->{terms},         $form->{id}
        );
    }
    $sth = $dbh->prepare($query);


    if ( !$did_insert ) {
        @queries = $form->run_custom_queries( 'oe', 'UPDATE' );
    }


    $form->{ordtotal} = $amount;
    $sth->execute(@queryargs) || $form->error($query);

    # add shipto
    $form->{name} = $form->{ $form->{vc} };
    $form->{name} =~ s/--$form->{"$form->{vc}_id"}//;

    $form->add_shipto( $dbh, $form->{id});

    # save printed, emailed, queued

    $form->save_status($dbh);

    if ( ( $form->{currency} ne $form->{defaultcurrency} ) && !$exchangerate ) {
        if ( $form->{vc} eq 'customer' ) {
            $form->update_exchangerate( $dbh, $form->{currency},
                $form->{transdate}, $form->{exchangerate}, 0 );
        }
        if ( $form->{vc} eq 'vendor' ) {
            $form->update_exchangerate( $dbh, $form->{currency},
                $form->{transdate}, 0, $form->{exchangerate} );
        }
    }

    if ( $form->{type} =~ /_order$/ ) {

        # adjust onhand
        &adj_onhand( $dbh, $form, $ml * -1 );
        &adj_inventory( $dbh, $myconfig, $form );
    }

    my %audittrail = (
        tablename => 'oe',
        reference => ( $form->{type} =~ /_order$/ )
        ? $form->{ordnumber}
        : $form->{quonumber},
        formname => $form->{type},
        action   => 'saved',
        id       => $form->{id}
    );

   # $form->audittrail( $dbh, "", \%audittrail );

    $form->save_recurring( $dbh, $myconfig );

    my $rc = $dbh->commit;

    $rc;
}

sub delete {
    my ( $self, $myconfig, $form ) = @_;

    # connect to database
    my $dbh = $form->{dbh};

    # delete spool files
    my $query = qq|
		SELECT spoolfile FROM status
		WHERE trans_id = ?
		AND spoolfile IS NOT NULL|;
    $sth = $dbh->prepare($query);
    $sth->execute( $form->{id} ) || $form->dberror($query);

    my $spoolfile;
    my @spoolfiles = ();

    while ( ($spoolfile) = $sth->fetchrow_array ) {
        push @spoolfiles, $spoolfile;
    }
    $sth->finish;

    $query = qq|
		SELECT o.parts_id, o.ship, p.inventory_accno_id, p.assembly
		FROM orderitems o
		JOIN parts p ON (p.id = o.parts_id)
		WHERE trans_id = ?|;
    $sth = $dbh->prepare($query);
    $sth->execute( $form->{id} ) || $form->dberror($query);

    if ( $form->{type} =~ /_order$/ ) {
        $ml = ( $form->{type} eq 'purchase_order' ) ? -1 : 1;
        while ( my ( $id, $ship, $inv, $assembly ) = $sth->fetchrow_array ) {
            $form->update_balance( $dbh, "parts", "onhand", "id = $id",
                $ship * $ml )
              if ( $inv || $assembly );
        }
    }
    $sth->finish;

    # delete inventory
    $query = qq|DELETE FROM inventory WHERE trans_id = ?|;
    $sth   = $dbh->prepare($query);
    $sth->execute( $form->{id} ) || $form->dberror($query);
    $sth->finish;

    # delete status entries
    $query = qq|DELETE FROM status WHERE trans_id = ?|;
    $sth   = $dbh->prepare($query);
    $sth->execute( $form->{id} ) || $form->dberror($query);
    $sth->finish;

    # delete OE record
    $query = qq|DELETE FROM oe WHERE id = ?|;
    $sth   = $dbh->prepare($query);
    $sth->execute( $form->{id} ) || $form->dberror($query);
    $sth->finish;

    # delete individual entries
    $query = qq|DELETE FROM orderitems WHERE trans_id = ?|;
    $sth->finish;

    $query = qq|DELETE FROM new_shipto WHERE trans_id = ?|;
    $sth   = $dbh->prepare($query);
    $sth->execute( $form->{id} ) || $form->dberror($query);
    $sth->finish;

    my %audittrail = (
        tablename => 'oe',
        reference => ( $form->{type} =~ /_order$/ )
        ? $form->{ordnumber}
        : $form->{quonumber},
        formname => $form->{type},
        action   => 'deleted',
        id       => $form->{id}
    );

    $form->audittrail( $dbh, "", \%audittrail );

    my $rc = $dbh->commit;

    if ($rc) {
        foreach $spoolfile (@spoolfiles) {
            unlink "${LedgerSMB::Sysconfig::spool}/$spoolfile" if $spoolfile;
        }
    }

    $rc;

}

sub retrieve {
    use LedgerSMB::PriceMatrix;
    my ( $self, $myconfig, $form ) = @_;

    # connect to database
    my $dbh = $form->{dbh};

    my $query;
    my $sth;
    my $var;
    my $ref;

    $query = qq|
		SELECT value, current_date FROM defaults
		 WHERE setting_key = 'curr'|;
    ( $form->{currencies}, $form->{transdate} ) = $dbh->selectrow_array($query);

    if ( $form->{id} ) {

        # retrieve order
        $query = qq|
			SELECT o.ordnumber, o.transdate, o.reqdate, o.terms,
                		o.taxincluded, o.shippingpoint, o.shipvia, 
				o.notes, o.intnotes, o.curr AS currency, 
				pe.first_name \|\| ' ' \|\| pe.last_name AS employee,
				o.person_id AS employee_id,
				o.entity_credit_account AS $form->{vc}_id, c.legal_name AS $form->{vc}, 
				o.amount AS invtotal, o.closed, o.reqdate, 
				o.quonumber, o.department_id, 
				d.description AS department, o.language_code, 
				o.ponumber
			FROM oe o
			JOIN entity_credit_account cr ON (cr.id = o.entity_credit_account)
			JOIN company c ON (cr.entity_id = c.entity_id)
			JOIN entity vc ON (c.entity_id = vc.id)
			LEFT JOIN person pe ON (o.person_id = pe.id)
			LEFT JOIN entity_employee e 
                                  ON (pe.entity_id = e.entity_id)
			LEFT JOIN department d ON (o.department_id = d.id)
			WHERE o.id = ?|;
        $sth = $dbh->prepare($query);
        $sth->execute( $form->{id} ) || $form->dberror($query);

        $ref = $sth->fetchrow_hashref('NAME_lc');
        $form->db_parse_numeric(sth=>$sth, hashref=>$ref);
        for ( keys %$ref ) { $form->{$_} = $ref->{$_} }
        $sth->finish;

        $query = qq|SELECT * FROM new_shipto WHERE trans_id = ?|;
        $sth   = $dbh->prepare($query);
        $sth->execute( $form->{id} ) || $form->dberror($query);

        $ref = $sth->fetchrow_hashref('NAME_lc');
        for ( keys %$ref ) { $form->{$_} = $ref->{$_} }
        $sth->finish;

        # get printed, emailed and queued
        $query = qq|
			SELECT s.printed, s.emailed, s.spoolfile, s.formname
			FROM status s
			WHERE s.trans_id = ?|;
        $sth = $dbh->prepare($query);
        $sth->execute( $form->{id} ) || $form->dberror($query);

        while ( $ref = $sth->fetchrow_hashref(NAME_lc) ) {
            $form->{printed} .= "$ref->{formname} "
              if $ref->{printed};
            $form->{emailed} .= "$ref->{formname} "
              if $ref->{emailed};
            $form->{queued} .= "$ref->{formname} $ref->{spoolfile} "
              if $ref->{spoolfile};
        }
        $sth->finish;
        for (qw(printed emailed queued)) { $form->{$_} =~ s/ +$//g }

        # retrieve individual items
        $query = qq|
			SELECT o.id AS orderitems_id, p.partnumber, p.assembly, 
				o.description, o.qty, o.sellprice, o.precision, 
				o.parts_id AS id, o.unit, o.discount, p.bin,
				o.reqdate, o.project_id, o.ship, o.serialnumber,
				o.notes, pr.projectnumber, pg.partsgroup, 
				p.partsgroup_id, p.partnumber AS sku,
				p.listprice, p.lastcost, p.weight, p.onhand,
				p.inventory_accno_id, p.income_accno_id, 
				p.expense_accno_id, t.description 
					AS partsgrouptranslation
			FROM orderitems o
			JOIN parts p ON (o.parts_id = p.id)
			LEFT JOIN project pr ON (o.project_id = pr.id)
			LEFT JOIN partsgroup pg ON (p.partsgroup_id = pg.id)
			LEFT JOIN translation t 
				ON (t.trans_id = p.partsgroup_id 
					AND t.language_code = ?)
			WHERE o.trans_id = ?
			ORDER BY o.id|;
        $sth = $dbh->prepare($query);
        $sth->execute( $form->{language_code}, $form->{id} )
          || $form->dberror($query);

        # foreign exchange rates
        &exchangerate_defaults( $dbh, $form );

        # query for price matrix
        my $pmh = PriceMatrix::price_matrix_query( $dbh, $form );

        # taxes
        $query = qq|
			SELECT c.accno FROM chart c
			JOIN partstax pt ON (pt.chart_id = c.id)
			WHERE pt.parts_id = ?|;
        my $tth = $dbh->prepare($query) || $form->dberror($query);

        my $taxrate;
        my $ptref;
        my $sellprice;
        my $listprice;

        while ( $ref = $sth->fetchrow_hashref('NAME_lc') ) {
            $form->db_parse_numeric(sth=>$sth, hashref=>$ref);

            ($decimalplaces) = ( $ref->{sellprice} =~ /\.(\d+)/ );
            $decimalplaces = length $decimalplaces;
            $decimalplaces = ( $decimalplaces > 2 ) ? $decimalplaces : 2;

            $tth->execute( $ref->{id} );
            $ref->{taxaccounts} = "";
            $taxrate = 0;

            while ( $ptref = $tth->fetchrow_hashref(NAME_lc) ) {
                $ref->{taxaccounts} .= "$ptref->{accno} ";
                $taxrate += $form->{"$ptref->{accno}_rate"};
            }
            $tth->finish;
            chop $ref->{taxaccounts};

            # preserve price
            $sellprice = $ref->{sellprice};

            # multiply by exchangerate
            $ref->{sellprice} =
              $form->round_amount(
                $ref->{sellprice} * $form->{ $form->{currency} },
                $decimalplaces );

            for (qw(listprice lastcost)) {
                $ref->{$_} =
                  $form->round_amount(
                    $ref->{$_} / $form->{ $form->{currency} },
                    $decimalplaces );
            }

            # partnumber and price matrix
            PriceMatrix::price_matrix( $pmh, $ref, $form->{transdate},
                $decimalplaces, $form, $myconfig );

            $ref->{sellprice} = $sellprice;

            $ref->{partsgroup} = $ref->{partsgrouptranslation}
              if $ref->{partsgrouptranslation};

            push @{ $form->{form_details} }, $ref;

        }
        $sth->finish;

        # get recurring transaction
        $form->get_recurring;

        @queries = $form->run_custom_queries( 'oe', 'SELECT' );
    }
    else {

        # get last name used
        $form->lastname_used( $myconfig, $dbh, $form->{vc} )
          unless $form->{"$form->{vc}_id"};

        delete $form->{notes};

    }

    $dbh->commit;

}

sub exchangerate_defaults {
    my ( $dbh2, $form ) = @_;
    $dbh = $form->{dbh};
    my $var;
    my $buysell = ( $form->{vc} eq "customer" ) ? "buy" : "sell";

    # get default currencies
    my $query = qq|
		SELECT substr(value,1,3), value FROM defaults
		 WHERE setting_key = 'curr'|;
    ( $form->{defaultcurrency}, $form->{currencies} ) =
      $dbh->selectrow_array($query);

    $query = qq|
		SELECT $buysell
		FROM exchangerate
		WHERE curr = ?
		AND transdate = ?|;
    my $eth1 = $dbh->prepare($query) || $form->dberror($query);
    $query = qq~
		SELECT max(transdate || ' ' || $buysell || ' ' || curr)
		FROM exchangerate
		WHERE curr = ?~;
    my $eth2 = $dbh->prepare($query) || $form->dberror($query);

    # get exchange rates for transdate or max
    foreach $var ( split /:/, substr( $form->{currencies}, 4 ) ) {
        $eth1->execute( $var, $form->{transdate} );
        my @exchangelist;
        @exchangelist = $eth1->fetchrow_array;
        $form->db_parse_numeric(sth=>$eth1, arrayref=>\@exchangelist);
        $form->{$var} = shift @array;
        if ( !$form->{$var} ) {
            $eth2->execute($var);
            @exchangelist = $eth2->fetchrow_array;
            $form->db_parse_numeric(sth=>$eth2, arrayref=>\@exchangelist);

            ( $form->{$var} ) = @exchangelist; 
            ( $null, $form->{$var} ) = split / /, $form->{$var};
            $form->{$var} = 1 unless $form->{$var};
            $eth2->finish;
        }
        $eth1->finish;
    }

    $form->{ $form->{currency} } = $form->{exchangerate}
      if $form->{exchangerate};
    $form->{ $form->{currency} } ||= 1;
    $form->{ $form->{defaultcurrency} } = 1;

}

sub order_details {
    use LedgerSMB::CP;
    my ( $self, $myconfig, $form ) = @_;

    # connect to database
    my $dbh = $form->{dbh};
    my $query;
    my $sth;

    my $item;
    my $i;
    my @sortlist = ();
    my $projectnumber;
    my $projectdescription;
    my $projectnumber_id;
    my $translation;
    my $partsgroup;

    my @queryargs;

    my @taxaccounts;
    my %taxaccounts;    # I don't think this works.
    my $tax;
    my $taxrate;
    my $taxamount;

    my %translations;

    my $language_code = $form->{dbh}->quote( $form->{language_code} );
    $query = qq|
		SELECT p.description, t.description
		FROM project p
		LEFT JOIN translation t ON (t.trans_id = p.id AND 
			t.language_code = $language_code)
	       WHERE id = ?|;
    my $prh = $dbh->prepare($query) || $form->dberror($query);

    $query = qq|
		SELECT inventory_accno_id, income_accno_id,
		expense_accno_id, assembly FROM parts
		WHERE id = ?|;
    my $pth = $dbh->prepare($query) || $form->dberror($query);

    my $sortby;

    # sort items by project and partsgroup
    for $i ( 1 .. $form->{rowcount} ) {

        if ( $form->{"id_$i"} ) {

            # account numbers
            $pth->execute( $form->{"id_$i"} );
            $ref = $pth->fetchrow_hashref(NAME_lc);
            for ( keys %$ref ) { $form->{"${_}_$i"} = $ref->{$_} }
            $pth->finish;

            $projectnumber_id      = 0;
            $projectnumber         = "";
            $form->{partsgroup}    = "";
            $form->{projectnumber} = "";

            if (   $form->{groupprojectnumber}
                || $form->{grouppartsgroup} )
            {

                $inventory_accno_id =
                  ( $form->{"inventory_accno_id_$i"} || $form->{"assembly_$i"} )
                  ? "1"
                  : "";

                if ( $form->{groupprojectnumber} ) {
                    ( $projectnumber, $projectnumber_id ) =
                      split /--/, $form->{"projectnumber_$i"};
                }
                if ( $form->{grouppartsgroup} ) {
                    ( $form->{partsgroup} ) = split /--/,
                      $form->{"partsgroup_$i"};
                }

                if (   $projectnumber_id
                    && $form->{groupprojectnumber} )
                {
                    if ( $translation{$projectnumber_id} ) {
                        $form->{projectnumber} =
                          $translation{$projectnumber_id};
                    }
                    else {

                        # get project description
                        $prh->execute($projectnumber_id);
                        ( $projectdescription, $translation ) =
                          $prh->fetchrow_array;
                        $prh->finish;

                        $form->{projectnumber} =
                          ($translation)
                          ? "$projectnumber, \n" . "$translation"
                          : "$projectnumber, \n" . "$projectdescription";

                        $translation{$projectnumber_id} =
                          $form->{projectnumber};
                    }
                }

                if (   $form->{grouppartsgroup}
                    && $form->{partsgroup} )
                {
                    $form->{projectnumber} .= " / "
                      if $projectnumber_id;
                    $form->{projectnumber} .= $form->{partsgroup};
                }

                $form->format_string($form->{projectnumber});

            }

            $sortby = qq|$projectnumber$form->{partsgroup}|;

            if ( $form->{sortby} ne 'runningnumber' ) {
                for (qw(partnumber description bin)) {
                    $sortby .= $form->{"${_}_$i"}
                      if $form->{sortby} eq $_;
                }
            }

            push @sortlist,
              [
                $i,
                "$projectnumber$form->{partsgroup}" . "$inventory_accno_id",
                $form->{projectnumber},
                $projectnumber_id,
                $form->{partsgroup},
                $sortby
              ];
        }

    }

    delete $form->{projectnumber};

    # sort the whole thing by project and group
    @sortlist = sort { $a->[5] cmp $b->[5] } @sortlist;

    # if there is a warehouse limit picking
    if ( $form->{warehouse_id} && $form->{formname} =~ /(pick|packing)_list/ ) {

        # run query to check for inventory
        $query = qq|
			SELECT sum(qty) AS qty FROM inventory
			WHERE parts_id = ? AND warehouse_id = ?|;
        $sth = $dbh->prepare($query) || $form->dberror($query);

        for $i ( 1 .. $form->{rowcount} ) {
            $sth->execute( $form->{"id_$i"}, $form->{warehouse_id} )
              || $form->dberror;

            my @qtylist = $sth->fetchrow_array;
            $form->db_parse_numeric(sth=>$sth, arrayref=>\@qtylist);

            ($qty) = @qtylist; $sth->fetchrow_array;
            $sth->finish;

            $form->{"qty_$i"} = 0 if $qty == 0;

            if ( $form->parse_amount( $myconfig, $form->{"ship_$i"} ) > $qty ) {
                $form->{"ship_$i"} = $form->format_amount( $myconfig, $qty );
            }
        }
    }

    my $runningnumber = 1;
    my $sameitem      = "";
    my $subtotal;
    my $k = scalar @sortlist;
    my $j = 0;

    foreach $item (@sortlist) {
        $i = $item->[0];
        $j++;

        if ( $form->{groupprojectnumber} || $form->{grouppartsgroup} ) {
            if ( $item->[1] ne $sameitem ) {
                $sameitem = $item->[1];

                $ok = 0;

                if ( $form->{groupprojectnumber} ) {
                    $ok = $form->{"projectnumber_$i"};
                }
                if ( $form->{grouppartsgroup} ) {
                    $ok = $form->{"partsgroup_$i"}
                      unless $ok;
                }

                if ($ok) {
                    if (   $form->{"inventory_accno_id_$i"}
                        || $form->{"assembly_$i"} )
                    {

                        push( @{ $form->{part} },    "" );
                        push( @{ $form->{service} }, NULL );
                    }
                    else {
                        push( @{ $form->{part} },    NULL );
                        push( @{ $form->{service} }, "" );
                    }

                    push( @{ $form->{description} }, $item->[2] );
                    for (
                        qw(taxrates runningnumber
                        number sku qty ship unit bin
                        serialnumber requiredate
                        projectnumber sellprice
                        listprice netprice discount
                        discountrate linetotal weight
                        itemnotes)
                      )
                    {
                        push( @{ $form->{$_} }, "" );
                    }
                    push( @{ $form->{lineitems} }, { amount => 0, tax => 0 } );
                }
            }
        }

        $form->{"qty_$i"} = $form->parse_amount( $myconfig, $form->{"qty_$i"} );
        $form->{"ship_$i"} =
          $form->parse_amount( $myconfig, $form->{"ship_$i"} );

        if ( $form->{"qty_$i"} ) {

            $form->{discount} = [] if ref $form->{discount} ne 'ARRAY';
            $form->{totalqty}  += $form->{"qty_$i"};
            $form->{totalship} += $form->{"ship_$i"};
            $form->{totalweight} +=
              ( $form->{"weight_$i"} * $form->{"qty_$i"} );
            $form->{totalweightship} +=
              ( $form->{"weight_$i"} * $form->{"ship_$i"} );

            # add number, description and qty to $form->{number}
            push( @{ $form->{runningnumber} }, $runningnumber++ );
            push( @{ $form->{number} },        qq|$form->{"partnumber_$i"}| );
            push( @{ $form->{sku} },           qq|$form->{"sku_$i"}| );
            push( @{ $form->{description} },   qq|$form->{"description_$i"}| );
            push( @{ $form->{itemnotes} },     $form->{"notes_$i"} );
            push(
                @{ $form->{qty} },
                $form->format_amount( $myconfig, $form->{"qty_$i"} )
            );
            push(
                @{ $form->{ship} },
                $form->format_amount( $myconfig, $form->{"ship_$i"} )
            );
            push( @{ $form->{unit} },         qq|$form->{"unit_$i"}| );
            push( @{ $form->{bin} },          qq|$form->{"bin_$i"}| );
            push( @{ $form->{serialnumber} }, qq|$form->{"serialnumber_$i"}| );
            push( @{ $form->{requiredate} },  qq|$form->{"reqdate_$i"}| );
            push( @{ $form->{projectnumber} },
                qq|$form->{"projectnumber_$i"}| );

            push( @{ $form->{sellprice} }, $form->{"sellprice_$i"} );

            push( @{ $form->{listprice} }, $form->{"listprice_$i"} );

            push(
                @{ $form->{weight} },
                $form->format_amount(
                    $myconfig, $form->{"weight_$i"} * $form->{"ship_$i"}
                )
            );

            my $sellprice =
              $form->parse_amount( $myconfig, $form->{"sellprice_$i"} );
            my ($dec) = ( $sellprice =~ /\.(\d+)/ );
            $dec = length $dec;
            my $decimalplaces = ( $dec > 2 ) ? $dec : 2;

            my $discount = $form->round_amount(
                $sellprice *
                  $form->parse_amount( $myconfig, $form->{"discount_$i"} ) /
                  100,
                $decimalplaces
            );

            # keep a netprice as well, (sellprice - discount)
            $form->{"netprice_$i"} = $sellprice - $discount;

            my $linetotal =
              $form->round_amount( $form->{"qty_$i"} * $form->{"netprice_$i"},
                2 );

            if (   $form->{"inventory_accno_id_$i"}
                || $form->{"assembly_$i"} )
            {

                push( @{ $form->{part} },    $form->{"sku_$i"} );
                push( @{ $form->{service} }, NULL );
                $form->{totalparts} += $linetotal;
            }
            else {
                push( @{ $form->{service} }, $form->{"sku_$i"} );
                push( @{ $form->{part} },    NULL );
                $form->{totalservices} += $linetotal;
            }

            push(
                @{ $form->{netprice} },
                ( $form->{"netprice_$i"} )
                ? $form->format_amount( $myconfig, $form->{"netprice_$i"},
                    $decimalplaces )
                : " "
            );

            $discount =
              ($discount)
              ? $form->format_amount( $myconfig, $discount * -1,
                $decimalplaces )
              : " ";

            push( @{ $form->{discount} }, $discount );
            push(
                @{ $form->{discountrate} },
                $form->format_amount( $myconfig, $form->{"discount_$i"} )
            );

            $form->{ordtotal} += $linetotal;

            # this is for the subtotals for grouping
            $subtotal += $linetotal;

            $form->{"linetotal_$i"} =
              $form->format_amount( $myconfig, $linetotal, 2 );
            push( @{ $form->{linetotal} }, $form->{"linetotal_$i"} );

            @taxaccounts = Tax::init_taxes( $form, $form->{"taxaccounts_$i"} , $form->{taxaccounts} );#limit to vendor/customer taxes, else invalid totals!!
            #$logger->trace("linetotal=".$form->{"linetotal_$i"}." i=$i taxaccounts_i=".$form->{"taxaccounts_$i"}." taxaccounts size=".scalar @taxaccounts);

            my $ml       = 1;
            my @taxrates = ();

            $tax = 0;

            $taxamount =
              Tax::calculate_taxes( \@taxaccounts, $form, $linetotal, 1 );
            $taxbase = Tax::extract_taxes( \@taxaccounts, $form, $linetotal );
            foreach $item (@taxaccounts) {
                push @taxrates, Math::BigFloat->new(100) * $item->rate;
                if ( $form->{taxincluded} ) {
                    $taxaccounts{ $item->account } += $item->value;
                    $taxbase{ $item->account }     += $taxbase;
                }
                else {
                    Tax::apply_taxes( \@taxaccounts, $form, $linetotal );
                    $taxbase{ $item->account }     += $linetotal;
                    $taxaccounts{ $item->account } += $item->value;
                }
            }
            if ( $form->{taxincluded} ) {
                $tax +=
                  Tax::calculate_taxes( \@taxaccounts, $form, $linetotal, 1 );
            }
            else {
                $tax +=
                  Tax::calculate_taxes( \@taxaccounts, $form, $linetotal, 0 );
            }

            push(
                @{ $form->{lineitems} },
                {
                    amount => $linetotal,
                    tax    => $form->round_amount( $tax, 2 )
                }
            );
            push( @{ $form->{taxrates} },
                join ' ', sort { $a <=> $b } @taxrates );

            if ( $form->{"assembly_$i"} ) {
                $form->{stagger} = -1;
                &assembly_details( $myconfig, $form, $dbh, $form->{"id_$i"},
                    $oid{ $myconfig->{dbdriver} },
                    $form->{"qty_$i"} );
            }

        }

        # add subtotal
        if ( $form->{groupprojectnumber} || $form->{grouppartsgroup} ) {
            if ($subtotal) {
                if ( $j < $k ) {

                    # look at next item
                    if ( $sortlist[$j]->[1] ne $sameitem ) {

                        if (   $form->{"inventory_accno_id_$i"}
                            || $form->{"assembly_$i"} )
                        {

                            push( @{ $form->{part} },    "" );
                            push( @{ $form->{service} }, NULL );
                        }
                        else {
                            push( @{ $form->{service} }, "" );
                            push( @{ $form->{part} },    NULL );
                        }

                        for (
                            qw(
                            taxrates runningnumber
                            number sku qty ship unit
                            bin serialnumber
                            requiredate
                            projectnumber sellprice
                            listprice netprice
                            discount discountrate
                            weight itemnotes)
                          )
                        {

                            push( @{ $form->{$_} }, "" );
                        }

                        push(
                            @{ $form->{description} },
                            $form->{groupsubtotaldescription}
                        );

                        push(
                            @{ $form->{lineitems} },
                            {
                                amount => 0,
                                tax    => 0
                            }
                        );

                        if ( $form->{groupsubtotaldescription} ne "" ) {
                            push(
                                @{ $form->{linetotal} },
                                $form->format_amount( $myconfig, $subtotal, 2 )
                            );
                        }
                        else {
                            push( @{ $form->{linetotal} }, "" );
                        }
                        $subtotal = 0;
                    }

                }
                else {

                    # got last item
                    if ( $form->{groupsubtotaldescription} ne "" ) {

                        if (   $form->{"inventory_accno_id_$i"}
                            || $form->{"assembly_$i"} )
                        {
                            push( @{ $form->{part} },    "" );
                            push( @{ $form->{service} }, NULL );
                        }
                        else {
                            push( @{ $form->{service} }, "" );
                            push( @{ $form->{part} },    NULL );
                        }

                        for (
                            qw(
                            taxrates runningnumber
                            number sku qty ship unit
                            bin serialnumber
                            requiredate
                            projectnumber sellprice
                            listprice netprice
                            discount discountrate
                            weight itemnotes)
                          )
                        {

                            push( @{ $form->{$_} }, "" );
                        }

                        push(
                            @{ $form->{description} },
                            $form->{groupsubtotaldescription}
                        );

                        push(
                            @{ $form->{linetotal} },
                            $form->format_amount( $myconfig, $subtotal, 2 )
                        );
                        push(
                            @{ $form->{lineitems} },
                            {
                                amount => 0,
                                tax    => 0
                            }
                        );
                    }
                }
            }
        }
    }

    $tax = 0;

    foreach $item ( sort keys %taxaccounts ) {
        if ( $form->round_amount( $taxaccounts{$item}, 2 ) ) {
            $tax += $taxamount = $form->round_amount( $taxaccounts{$item}, 2 );

            push(
                @{ $form->{taxbaseinclusive} },
                $form->{"${item}_taxbaseinclusive"} =
                  $form->round_amount( $taxbase{$item} + $tax, 2 )
            );
            push(
                @{ $form->{taxbase} },
                $form->{"${item}_taxbase"} =
                  $form->format_amount( $myconfig, $taxbase{$item}, 2 )
            );
            push(
                @{ $form->{tax} },
                $form->{"${item}_tax"} =
                  $form->format_amount( $myconfig, $taxamount, 2 )
            );

            push( @{ $form->{taxdescription} },
                $form->{"${item}_description"} );

            $form->{"${item}_taxrate"} =
              $form->format_amount( $myconfig, $form->{"${item}_rate"} * 100 );

            push( @{ $form->{taxrate} }, $form->{"${item}_taxrate"} );

            push( @{ $form->{taxnumber} }, $form->{"${item}_taxnumber"} );
        }
    }

    # adjust taxes for lineitems
    my $total = 0;
    for ( @{ $form->{lineitems} } ) {
        $total += $_->{tax};
    }
    if ( $form->round_amount( $total, 2 ) != $form->round_amount( $tax, 2 ) ) {

        # get largest amount
        for ( reverse sort { $a->{tax} <=> $b->{tax} } @{ $form->{lineitems} } )
        {

            $_->{tax} -= $total - $tax;
            last;
        }
    }
    $i = 1;
    for ( @{ $form->{lineitems} } ) {
        push(
            @{ $form->{linetax} },
            $form->format_amount( $myconfig, $_->{tax}, 2, "" )
        );
    }

    for (qw(totalparts totalservices)) {
        $form->{$_} = $form->format_amount( $myconfig, $form->{$_}, 2 );
    }
    for (qw(totalqty totalship totalweight)) {
        $form->{$_} = $form->format_amount( $myconfig, $form->{$_} );
    }
    $form->{subtotal} = $form->format_amount( $myconfig, $form->{ordtotal}, 2 );
    $form->{ordtotal} =
      ( $form->{taxincluded} )
      ? $form->{ordtotal}
      : $form->{ordtotal} + $tax;

    my $c;
    if ( $form->{language_code} ne "" ) {
        $c = new CP $form->{language_code};
    }
    else {
        $c = new CP $myconfig->{countrycode};
    }
    $c->init;
    my $whole;
    ( $whole, $form->{decimal} ) = split /\./, $form->{ordtotal};
    $form->{decimal} .= "00";
    $form->{decimal} = substr( $form->{decimal}, 0, 2 );

    $form->{text_decimal}   = $c->num2text( $form->{decimal} * 1 );
    $form->{text_amount}    = $c->num2text($whole);
    $form->{integer_amount} = $form->format_amount( $myconfig, $whole );

    # format amounts
    $form->{quototal} = $form->{ordtotal} =
      $form->format_amount( $myconfig, $form->{ordtotal}, 2 );

    $form->format_string(qw(text_amount text_decimal));

    $query = qq|
		SELECT value FROM defaults 
		 WHERE setting_key = 'weightunit'|;
    ( $form->{weightunit} ) = $dbh->selectrow_array($query);

    $dbh->commit;

}

sub assembly_details {
    my ( $myconfig, $form, $dbh, $id, $oid, $qty ) = @_;

    my $sm = "";
    my $spacer;

    $form->{stagger}++;
    if ( $form->{format} eq 'html' ) {
        $spacer = "&nbsp;" x ( 3 * ( $form->{stagger} - 1 ) )
          if $form->{stagger} > 1;
    }
    if ( $form->{format} =~ /(postscript|pdf)/ ) {
        if ( $form->{stagger} > 1 ) {
            $spacer = ( $form->{stagger} - 1 ) * 3;
            $spacer = '\rule{' . $spacer . 'mm}{0mm}';
        }
    }

    # get parts and push them onto the stack
    my $sortorder = "";

    if ( $form->{grouppartsgroup} ) {
        $sortorder = qq|ORDER BY pg.partsgroup, a.id|;
    }
    else {
        $sortorder = qq|ORDER BY a.id|;
    }

    my $where =
      ( $form->{formname} eq 'work_order' )
      ? "1 = 1"
      : "a.bom = '1'";

    my $query = qq|
		SELECT p.partnumber, p.description, p.unit, a.qty, 
			pg.partsgroup, p.partnumber AS sku, p.assembly, p.id, 
			p.bin
		FROM assembly a
		JOIN parts p ON (a.parts_id = p.id)
		LEFT JOIN partsgroup pg ON (p.partsgroup_id = pg.id)
		WHERE $where
		AND a.id = ?
		$sortorder|;
    my $sth = $dbh->prepare($query);
    $sth->execute($id) || $form->dberror($query);

    while ( my $ref = $sth->fetchrow_hashref(NAME_lc) ) {
        $form->db_parse_numeric(sth=>$sth, hashref=>$ref);

        for (qw(partnumber description partsgroup)) {
            $form->{"a_$_"} = $ref->{$_};
            $form->format_string("a_$_");
        }

        if ( $form->{grouppartsgroup} && $ref->{partsgroup} ne $sm ) {
            for (
                qw(
                taxrates number sku unit qty runningnumber ship
                bin serialnumber requiredate projectnumber
                sellprice listprice netprice discount
                discountrate linetotal weight itemnotes)
              )
            {

                push( @{ $form->{$_} }, "" );
            }
            $sm = ( $form->{"a_partsgroup"} ) ? $form->{"a_partsgroup"} : "";
            push( @{ $form->{description} }, "$spacer$sm" );

            push( @{ $form->{lineitems} }, { amount => 0, tax => 0 } );

        }

        if ( $form->{stagger} ) {

            push(
                @{ $form->{description} },
                qq|$spacer$form->{"a_partnumber"}, |
                  . qq|$form->{"a_description"}|
            );

            for (
                qw(
                taxrates number sku runningnumber ship
                serialnumber requiredate projectnumber
                sellprice listprice netprice discount
                discountrate linetotal weight itemnotes)
              )
            {

                push( @{ $form->{$_} }, "" );
            }

        }
        else {

            push( @{ $form->{description} }, qq|$form->{"a_description"}| );
            push( @{ $form->{sku} },         $form->{"a_partnumber"} );
            push( @{ $form->{number} },      $form->{"a_partnumber"} );

            for (
                qw(
                taxrates runningnumber ship serialnumber
                requiredate projectnumber sellprice listprice
                netprice discount discountrate linetotal weight
                itemnotes)
              )
            {

                push( @{ $form->{$_} }, "" );
            }

        }

        push( @{ $form->{lineitems} }, { amount => 0, tax => 0 } );

        push(
            @{ $form->{qty} },
            $form->format_amount( $myconfig, $ref->{qty} * $qty )
        );

        for (qw(unit bin)) {
            $form->{"a_$_"} = $ref->{$_};
            $form->format_string("a_$_");
            push( @{ $form->{$_} }, $form->{"a_$_"} );
        }

        if ( $ref->{assembly} && $form->{formname} eq 'work_order' ) {
            &assembly_details( $myconfig, $form, $dbh, $ref->{id}, $oid,
                $ref->{qty} * $qty );
        }

    }
    $sth->finish;

    $form->{stagger}--;

}

sub project_description {
    my ( $self, $dbh, $id ) = @_;

    my $query = qq|
		SELECT description
		FROM project
		WHERE id = $id|;
    ($_) = $dbh->selectrow_array($query);

    $_;

}

sub get_warehouses {
    my ( $self, $myconfig, $form ) = @_;

    my $dbh = $form->{dbh};

    # setup warehouses
    my $query = qq|
		SELECT id, description
		FROM warehouse
		ORDER BY 2|;

    my $sth = $dbh->prepare($query);
    $sth->execute || $form->dberror($query);

    while ( my $ref = $sth->fetchrow_hashref(NAME_lc) ) {
        push @{ $form->{all_warehouse} }, $ref;
    }
    $sth->finish;

}

sub save_inventory {
    my ( $self, $myconfig, $form ) = @_;

    my ( $null, $warehouse_id ) = split /--/, $form->{warehouse};
    $warehouse_id *= 1;

    my $ml = ( $form->{type} eq 'ship_order' ) ? -1 : 1;

    my $dbh = $form->{dbh};
    my $sth;
    my $wth;
    my $serialnumber;
    my $ship;
    my $employee_id;

    ( $null, $employee_id ) = split /--/, $form->{employee};
    ( $null, $employee_id ) = $form->get_employee($dbh) if !$employee_id;

    $query = qq|
		SELECT serialnumber, ship
		FROM orderitems
		WHERE trans_id = ?
		AND id = ?
		FOR UPDATE|;
    $sth = $dbh->prepare($query) || $form->dberror($query);

    $query = qq|
		SELECT sum(qty)
		FROM inventory
		WHERE parts_id = ?
		AND warehouse_id = ?|;
    $wth = $dbh->prepare($query) || $form->dberror($query);

    for my $i ( 1 .. $form->{rowcount} ) {
        $form->{"ship_$i"} = 0 unless $form->{"ship_$i"};

        $ship =
          ( abs( $form->{"ship_$i"} ) > abs( $form->{"qty_$i"} ) )
          ? $form->{"qty_$i"}
          : $form->{"ship_$i"};

        if ( $warehouse_id && $form->{type} eq 'ship_order' ) {

            $wth->execute( $form->{"id_$i"}, $warehouse_id )
              || $form->dberror;

            @qtylist = $wth->fetchrow_array;
            $form->db_parse_numeric(sth=>$wth, arrayref=>\@qtylist);
            ($qty) = @qtylist;
            $wth->finish;

            if ( $ship > $qty ) {
                $ship = $qty;
            }
        }

        if ($ship) {

            if ( !$form->{shippingdate} ) {
                $form->{shippingdate} = undef;
            }

            $ship *= $ml;
            $query = qq|
				INSERT INTO inventory 
					(parts_id, warehouse_id, qty, trans_id, 
					orderitems_id, shippingdate, 
					employee_id)
				VALUES 
					(?, ?, ?, ?, ?, ?, ?)|;
            $sth2 = $dbh->prepare($query);
            $sth2->execute( $form->{"id_$i"}, $warehouse_id, $ship,
                $form->{"id"}, $form->{"orderitems_id_$i"},
                $form->{shippingdate}, $employee_id )
              || $form->dberror($query);
            $sth2->finish;

            # add serialnumber, ship to orderitems
            $sth->execute( $form->{id}, $form->{"orderitems_id_$i"} )
              || $form->dberror;
            ( $serialnumber, $ship ) = $sth->fetchrow_array;
            $sth->finish;

            $serialnumber .= " " if $serialnumber;
            $serialnumber .= qq|$form->{"serialnumber_$i"}|;
            $ship += $form->{"ship_$i"};

            $query = qq|
				UPDATE orderitems SET
					serialnumber = ?,
					ship = ?,
					reqdate = ?
					WHERE trans_id = ?
				AND id = ?|;
            $sth2 = $dbh->prepare($query);
            $sth2->execute( $serialnumber, $ship, $form->{shippingdate},
                $form->{id}, $form->{"orderitems_id_$i"} )
              || $form->dberror($query);
            $sth2->finish;

            # update order with ship via
            $query = qq|
				UPDATE oe SET
					shippingpoint = ?,
					shipvia = ?
				WHERE id = ?|;
            $sth2 = $dbh->prepare($query);
            $sth2->execute( $form->{shippingpoint},
                $form->{shipvia}, $form->{id} )
              || $form->dberror($query);
            $sth2->finish;

            # update onhand for parts
            $form->update_balance(
                $dbh, "parts", "onhand",
                qq|id = $form->{"id_$i"}|,
                $form->{"ship_$i"} * $ml
            );

        }
    }

    my $rc = $dbh->commit;

    $rc;

}

sub adj_onhand {
    my ( $dbh, $form, $ml ) = @_;

    my $query = qq|
		SELECT oi.parts_id, oi.ship, p.inventory_accno_id, p.assembly
		FROM orderitems oi
		JOIN parts p ON (p.id = oi.parts_id)
		WHERE oi.trans_id = ?|;
    my $sth = $dbh->prepare($query);
    $sth->execute( $form->{id} ) || $form->dberror($query);

    $query = qq|
		SELECT sum(p.inventory_accno_id), p.assembly
		FROM parts p
		JOIN assembly a ON (a.parts_id = p.id)
		WHERE a.id = ?
		GROUP BY p.assembly|;
    my $ath = $dbh->prepare($query) || $form->dberror($query);

    my $ref;

    while ( $ref = $sth->fetchrow_hashref(NAME_lc) ) {

        if ( $ref->{inventory_accno_id} || $ref->{assembly} ) {

            # do not update if assembly consists of all services
            if ( $ref->{assembly} ) {
                $ath->execute( $ref->{parts_id} )
                  || $form->dberror($query);

                my ( $inv, $assembly ) = $ath->fetchrow_array;
                $ath->finish;

                next unless ( $inv || $assembly );

            }

            # adjust onhand in parts table
            $form->update_balance(
                $dbh, "parts", "onhand",
                qq|id = $ref->{parts_id}|,
                $ref->{ship} * $ml
            );
        }
    }

    $sth->finish;

}

sub adj_inventory {
    my ( $dbh, $myconfig, $form ) = @_;

    # increase/reduce qty in inventory table
    my $query = qq|
		SELECT oi.id, oi.parts_id, oi.ship
		FROM orderitems oi
		WHERE oi.trans_id = ?|;
    my $sth = $dbh->prepare($query);
    $sth->execute( $form->{id} ) || $form->dberror($query);

    my $id = $dbh->quote( $form->{id} );
    $query = qq|
		SELECT qty,
			(SELECT SUM(qty) FROM inventory
			WHERE trans_id = $id
			AND orderitems_id = ?) AS total
		FROM inventory
		WHERE trans_id = $id
		AND orderitems_id = ?|;
    my $ith = $dbh->prepare($query) || $form->dberror($query);

    my $qty;
    my $ml = ( $form->{type} =~ /(ship|sales)_order/ ) ? -1 : 1;

    while ( my $ref = $sth->fetchrow_hashref(NAME_lc) ) {

        $ith->execute( $ref->{id}, $ref->{id} ) || $form->dberror($query);

        my $ship = $ref->{ship};
        while ( my $inv = $ith->fetchrow_hashref(NAME_lc) ) {

            if ( ( $qty = ( ( $inv->{total} * $ml ) - $ship ) ) >= 0 ) {
                $qty = $inv->{qty} * $ml
                  if ( $qty > ( $inv->{qty} * $ml ) );

                $form->update_balance(
                    $dbh, "inventory", "qty",
                    qq|$oid{$myconfig->{dbdriver}} | . qq|= $inv->{oid}|,
                    $qty * -1 * $ml
                );
                $ship -= $qty;
            }
        }
        $ith->finish;

    }
    $sth->finish;

    # delete inventory entries if qty = 0
    $query = qq|
		DELETE FROM inventory
		WHERE trans_id = ?
		AND qty = 0|;
    $sth = $dbh->prepare($query);
    $sth->execute( $form->{id} ) || $form->dberror($query);

}

sub get_inventory {
    my ( $self, $myconfig, $form ) = @_;

    my $where;
    my $query;
    my $null;
    my $fromwarehouse_id;
    my $towarehouse_id;
    my $var;

    my $dbh = $form->{dbh};

    if ( $form->{partnumber} ne "" ) {
        $var = $dbh->quote( $form->like( lc $form->{partnumber} ) );
        $where .= "
			AND lower(p.partnumber) LIKE $var";
    }
    if ( $form->{description} ne "" ) {
        $var = $dbh->quote( $form->like( lc $form->{description} ) );
        $where .= "
			AND lower(p.description) LIKE $var";
    }
    if ( $form->{partsgroup} ne "" ) {
        ( $null, $var ) = split /--/, $form->{partsgroup};
        $var = $dbh->quote($var);
        $where .= "
			AND pg.id = $var";
    }

    ( $null, $fromwarehouse_id ) = split /--/, $form->{fromwarehouse};
    $fromwarehouse_id = $dbh->quote($fromwarehouse_id);

    ( $null, $towarehouse_id ) = split /--/, $form->{towarehouse};
    $towarehouse_id = $dbh->quote($towarehouse_id);

    my %ordinal = (
        partnumber  => 2,
        description => 3,
        partsgroup  => 5,
        warehouse   => 6,
    );

    my @a = qw( partnumber warehouse );
    my $sortorder = $form->sort_order( \@a, \%ordinal );

    if ($fromwarehouse_id ne 'NULL') {
        if ($towarehouse_id ne 'NULL') {
            $where .= "
				AND NOT i.warehouse_id = $towarehouse_id";
        }
        $query = qq|
			SELECT p.id, p.partnumber, p.description,
				sum(i.qty) * 2 AS onhand, sum(i.qty) AS qty,
				pg.partsgroup, w.description AS warehouse, 
				i.warehouse_id
			FROM inventory i
			JOIN parts p ON (p.id = i.parts_id)
			LEFT JOIN partsgroup pg ON (p.partsgroup_id = pg.id)
			LEFT JOIN warehouse w ON (w.id = i.warehouse_id)
			WHERE (i.warehouse_id = $fromwarehouse_id OR 
				i.warehouse_id IS NULL)
			$where
			GROUP BY p.id, p.partnumber, p.description, 
				pg.partsgroup, w.description, i.warehouse_id 
			ORDER BY $sortorder|;
    }
    else {
        if ($towarehouse_id) {
            $query = qq|
				SELECT p.id, p.partnumber, p.description,
					p.onhand, 
						(SELECT SUM(qty) 
						FROM inventory i 
						WHERE i.parts_id = p.id) AS qty,
					pg.partsgroup, '' AS warehouse, 
					0 AS warehouse_id
				FROM parts p
				LEFT JOIN partsgroup pg 
					ON (p.partsgroup_id = pg.id)
				WHERE p.onhand > 0 
					$where
				UNION|;
        }

        $query .= qq|
			SELECT p.id, p.partnumber, p.description,
				sum(i.qty) * 2 AS onhand, sum(i.qty) AS qty,
				pg.partsgroup, w.description AS warehouse, 
				i.warehouse_id
			FROM inventory i
			JOIN parts p ON (p.id = i.parts_id)
			LEFT JOIN partsgroup pg ON (p.partsgroup_id = pg.id)
			LEFT JOIN warehouse w ON (w.id = i.warehouse_id)
			WHERE i.warehouse_id != $towarehouse_id
				$where
			GROUP BY p.id, p.partnumber, p.description, 
				pg.partsgroup, w.description, i.warehouse_id
			ORDER BY $sortorder|;
    }

    my $sth = $dbh->prepare($query);
    $sth->execute || $form->dberror($query);

    while ( $ref = $sth->fetchrow_hashref(NAME_lc) ) {
        $form->db_parse_numeric(sth=>$sth, hashref=>$ref);
        $ref->{qty} = $ref->{onhand} - $ref->{qty};
        push @{ $form->{all_inventory} }, $ref if $ref->{qty} > 0;
    }
    $sth->finish;

    $dbh->commit;
}

sub transfer {
    my ( $self, $myconfig, $form ) = @_;

    my $dbh = $form->{dbh};

    ( $form->{employee}, $form->{employee_id} ) = $form->get_employee($dbh);

    my @a = localtime;
    $a[5] += 1900;
    $a[4]++;
    $a[4] = substr( "0$a[4]", -2 );
    $a[3] = substr( "0$a[3]", -2 );
    $shippingdate = "$a[5]$a[4]$a[3]";

    my %total = ();

    my $query = qq|
		INSERT INTO inventory
			(warehouse_id, parts_id, qty, shippingdate, employee_id)
		VALUES (?, ?, ?, ?, ?)|;
    $sth = $dbh->prepare($query) || $form->dberror($query);

    my $qty;

    for my $i ( 1 .. $form->{rowcount} ) {
        $qty = $form->parse_amount( $myconfig, $form->{"transfer_$i"} );

        $qty = $form->{"qty_$i"} if ( $qty > $form->{"qty_$i"} );

        if ( $qty > 0 ) {

            # to warehouse
            if ( $form->{warehouse_id} ) {
                $sth->execute( $form->{warehouse_id}, $form->{"id_$i"}, $qty,
                    $shippingdate, $form->{employee_id} )
                  || $form->dberror;
                $sth->finish;
            }

            # from warehouse
            if ( $form->{"warehouse_id_$i"} ) {
                $sth->execute( $form->{"warehouse_id_$i"},
                    $form->{"id_$i"}, $qty * -1, $shippingdate, 
                    $form->{employee_id})
                  || $form->dberror;
                $sth->finish;
            }
        }
    }

    my $rc = $dbh->commit;

    $rc;

}

sub get_soparts {
    my ( $self, $myconfig, $form ) = @_;

    # connect to database
    my $dbh = $form->{dbh};

    my $id;
    my $ref;

    # store required items from selected sales orders
    my $query = qq|
		SELECT p.id, oi.qty - oi.ship AS required, p.assembly
		FROM orderitems oi
		JOIN parts p ON (p.id = oi.parts_id)
		WHERE oi.trans_id = ?|;
    my $sth = $dbh->prepare($query) || $form->dberror($query);

    for ( my $i = 1 ; $i <= $form->{rowcount} ; $i++ ) {

        if ( $form->{"ndx_$i"} ) {

            $sth->execute( $form->{"ndx_$i"} );

            while ( $ref = $sth->fetchrow_hashref(NAME_lc) ) {
                $form->db_parse_numeric(sth=>$sth, hashref=>$ref);
                &add_items_required( "", $dbh, $form, $ref->{id},
                    $ref->{required}, $ref->{assembly} );
            }
            $sth->finish;
        }

    }

    $query = qq|SELECT current_date|;
    ( $form->{transdate} ) = $dbh->selectrow_array($query);

    # foreign exchange rates
    &exchangerate_defaults( $dbh, $form );

    $dbh->commit;

}

sub add_items_required {
    my ( $self, $dbh, $form, $parts_id, $required, $assembly ) = @_;

    my $query;
    my $sth;
    my $ref;

    if ($assembly) {
        $query = qq|
			SELECT p.id, a.qty, p.assembly 
			FROM assembly a
			JOIN parts p ON (p.id = a.parts_id)
			WHERE a.id = ?|;
        $sth = $dbh->prepare($query);
        $sth->execute($parts_id) || $form->dberror($query);

        while ( $ref = $sth->fetchrow_hashref(NAME_lc) ) {
            $form->db_parse_numeric(sth=> $sth, hashref=> $ref);
            &add_items_required( "", $dbh, $form, $ref->{id},
                $required * $ref->{qty},
                $ref->{assembly} );
        }
        $sth->finish;

    }
    else {

        $query = qq|
			SELECT partnumber, description, lastcost
			FROM parts
			WHERE id = ?|;
        $sth = $dbh->prepare($query);
        $sth->execute($parts_id) || $form->dberror($query);
        $ref = $sth->fetchrow_hashref(NAME_lc);
        $form->db_parse_numeric(sth=>$sth, hashref=>$ref);
        for ( keys %$ref ) {
            $form->{orderitems}{$parts_id}{$_} = $ref->{$_};
        }
        $sth->finish;

        $form->{orderitems}{$parts_id}{required} += $required;

        $query = qq|
			SELECT pv.partnumber, pv.leadtime, pv.lastcost, pv.curr,
				v.id as vendor_id, v.name
			FROM partsvendor pv
			JOIN vendor v ON (v.id = pv.credit_id)
			WHERE pv.parts_id = ?|;
        $sth = $dbh->prepare($query) || $form->dberror($query);

        # get cost and vendor
        $sth->execute($parts_id);

        while ( $ref = $sth->fetchrow_hashref(NAME_lc) ) {
            for ( keys %$ref ) {
                $form->{orderitems}{$parts_id}{partsvendor}{ $ref->{vendor_id} }
                  {$_} = $ref->{$_};
            }
        }
        $sth->finish;

    }

}

sub generate_orders {
    my ( $self, $myconfig, $form ) = @_;

    my $i;
    my %a;
    my $query;
    my $sth;

    for ( $i = 1 ; $i <= $form->{rowcount} ; $i++ ) {
        for (qw(qty lastcost)) {
            $form->{"${_}_$i"} =
              $form->parse_amount( $myconfig, $form->{"${_}_$i"} );
        }

        if ( $form->{"qty_$i"} ) {
            ( $vendor, $vendor_id ) =
              split /--/, $form->{"vendor_$i"};
            if ($vendor_id) {
                $a{$vendor_id}{ $form->{"id_$i"} }{qty} += $form->{"qty_$i"};
                for (qw(curr lastcost)) {
                    $a{$vendor_id}{ $form->{"id_$i"} }{$_} = $form->{"${_}_$i"};
                }
            }
        }
    }

    # connect to database
    my $dbh = $form->{dbh};

    # foreign exchange rates
    &exchangerate_defaults( $dbh, $form );

    my $amount;
    my $netamount;
    my $curr = "";
    my %tax;
    my $taxincluded = 0;
    my $vendor_id;

    my $description;
    my $unit;

    my $sellprice;

    foreach $vendor_id ( keys %a ) {

        %tax = ();

        $query = qq|
			SELECT v.curr, v.taxincluded, t.rate, c.accno
			FROM vendor v
			LEFT JOIN vendortax vt ON (v.id = vt.vendor_id)
			LEFT JOIN tax t ON (t.chart_id = vt.chart_id)
			LEFT JOIN chart c ON (c.id = t.chart_id)
			WHERE v.id = ?|;
        $sth = $dbh->prepare($query);
        $sth->execute($vendor_id) || $form->dberror($query);
        while ( $ref = $sth->fetchrow_hashref(NAME_lc) ) {
            $form->db_parse_numeric(sth=>$sth, hashref=> $ref);
            $curr                 = $ref->{curr};
            $taxincluded          = $ref->{taxincluded};
            $tax{ $ref->{accno} } = $ref->{rate};
        }
        $sth->finish;

        $curr ||= $form->{defaultcurrency};
        $taxincluded *= 1;

        my $uid = localtime;
        $uid .= "$$";

        # TODO:  Make this function insert as much as possible
        $query = qq|
			INSERT INTO oe (ordnumber)
			VALUES ('$uid')|;
        $dbh->do($query) || $form->dberror($query);

        $query = qq|SELECT id FROM oe WHERE ordnumber = '$uid'|;
        $sth   = $dbh->prepare($query);
        $sth->execute || $form->dberror($query);
        my ($id) = $sth->fetchrow_array;
        $sth->finish;

        $amount    = 0;
        $netamount = 0;

        foreach my $parts_id ( keys %{ $a{$vendor_id} } ) {

            if ( ( $form->{$curr} * $form->{ $a{$vendor_id}{$parts_id}{curr} } )
                > 0 )
            {

                $sellprice =
                  $a{$vendor_id}{$parts_id}{lastcost} / $form->{$curr} *
                  $form->{ $a{$vendor_id}{$parts_id}{curr} };
            }
            else {
                $sellprice = $a{$vendor_id}{$parts_id}{lastcost};
            }
            $sellprice = $form->round_amount( $sellprice, 2 );

            my $linetotal =
              $form->round_amount( $sellprice * $a{$vendor_id}{$parts_id}{qty},
                2 );

            $query = qq|
				SELECT p.description, p.unit, c.accno 
				FROM parts p
				LEFT JOIN partstax pt ON (p.id = pt.parts_id)
				LEFT JOIN chart c ON (c.id = pt.chart_id)
				WHERE p.id = ?|;
            $sth = $dbh->prepare($query);
            $sth->execute($parts_id) || $form->dberror($query);

            my $rate  = 0;
            my $taxes = '';
            while ( $ref = $sth->fetchrow_hashref(NAME_lc) ) {
                $description = $ref->{description};
                $unit        = $ref->{unit};
                $rate += $tax{ $ref->{accno} };
                $taxes .= "$ref->{accno} ";
            }
            $sth->finish;
            chop $taxes;
            my @taxaccounts = Tax::init_taxes( $form, $taxes );

            $netamount += $linetotal;
            if ($taxincluded) {
                $amount += $linetotal;
            }
            else {
                $amount +=
                  $form->round_amount(
                    Tax::apply_taxes( \@taxaccounts, $form, $linetotal ), 2 );
            }

            $query = qq|
				INSERT INTO orderitems 
					(trans_id, parts_id, description,
					qty, ship, sellprice, unit) 
				VALUES
					(?, ?, ?, ?, 0, ?, ?)|;
            $sth = $dbh->prepare($query);
            $sth->execute( $id, $parts_id, $description,
                $a{$vendor_id}{$parts_id}{qty},
                $sellprice, $unit )
              || $form->dberror($query);

        }

        my $ordnumber = $form->update_defaults( $myconfig, 'ponumber' );

        my $null;
        my $employee_id;
        my $department_id;

        ( $null, $employee_id ) = $form->get_employee($dbh);
        ( $null, $department_id ) = split /--/, $form->{department};
        $department_id *= 1;

        $query = qq|
			UPDATE oe SET
				ordnumber = ?,
				transdate = current_date,
				entity_id = ?
				amount = ?,
				netamount = ?,
				taxincluded = ?,
				curr = ?,
				employee_id = ?,
				department_id = ?,
				ponumber = ?
			WHERE id = ?|;
        $sth = $dbh->prepare($query);
        $sth->execute(
            $ordnumber,   $vendor_id,     $amount,
            $netamount,   $taxincluded,   $curr,
            $employee_id, $department_id, $form->{ponumber},
            $id
        ) || $form->dberror($query);

    }

    my $rc = $dbh->commit;

    $rc;

}

sub consolidate_orders {
    my ( $self, $myconfig, $form ) = @_;

    # connect to database
    my $dbh = $form->{dbh};

    my $i;
    my $id;
    my $ref;
    my %oe = ();

    my $query = qq|SELECT * FROM oe WHERE id = ?|;
    my $sth = $dbh->prepare($query) || $form->dberror($query);

    my $credit_account;
    my $oe_class_id;
    for ( $i = 1 ; $i <= $form->{rowcount} ; $i++ ) {

        # retrieve order
        if ( $form->{"ndx_$i"} ) {
            $sth->execute( $form->{"ndx_$i"} );

            $ref = $sth->fetchrow_hashref(NAME_lc);

	    $form->error( "Can't consolidate orders from different accounts" )
		if (defined( $credit_account )
     		    && ($credit_account != $ref->{entity_credit_account}));
	    $credit_account = $ref->{entity_credit_account};
            $oe_class_id = $ref->{oe_class_id};

            $ref->{ndx} = $i;
            $oe{oe}{ $ref->{curr} }{ $ref->{id} } = $ref;

            $oe{vc}{ $ref->{curr} }{ $ref->{"$form->{vc}_id"} }++;
            $sth->finish;
        }
    }

    $query = qq|SELECT * FROM orderitems WHERE trans_id = ?|;
    $sth = $dbh->prepare($query) || $form->dberror($query);

    foreach $curr ( keys %{ $oe{oe} } ) {

        foreach $id (
            sort { $oe{oe}{$curr}{$a}->{ndx} <=> $oe{oe}{$curr}{$b}->{ndx} }
            keys %{ $oe{oe}{$curr} }
          )
        {

            # retrieve order
            $vc_id = $oe{oe}{$curr}{$id}->{"$form->{vc}_id"};

            if ( $oe{vc}{ $oe{oe}{$curr}{$id}->{curr} }{$vc_id} > 1 ) {

                push @{ $oe{orders}{$curr}{$vc_id} }, $id;

                $sth->execute($id);
                while ( $ref = $sth->fetchrow_hashref(NAME_lc) ) {
                    push @{ $oe{orderitems}{$curr}{$id} }, $ref;
                }
                $sth->finish;

            }
        }
    }

    my $ordnumber = $form->{ordnumber};
    my $numberfld = ( $form->{vc} eq 'customer' ) ? 'sonumber' : 'ponumber';

    my ( $department, $department_id ) = $form->{department};
    $department_id *= 1;

    my $uid = localtime;
    $uid .= "$$";

    my @orderitems = ();

    foreach $curr ( keys %{ $oe{orders} } ) {

        foreach $vc_id ( sort { $a <=> $b } keys %{ $oe{orders}{$curr} } ) {

            # the orders
            @orderitems = ();
            $form->{entity_id} = $vc_id;
            $amount                   = 0;
            $netamount                = 0;
            my @orderids;
            my $orderid_str = "";

            foreach $id ( @{ $oe{orders}{$curr}{$vc_id} } ) {
                push(@orderids, $id);
                $orderid_str .= "?, ";

                # header
                $ref = $oe{oe}{$curr}{$id};

                $amount    += $ref->{amount};
                $netamount += $ref->{netamount};

                $id = $dbh->quote($id);
                foreach $item ( @{ $oe{orderitems}{$curr}{$id} } ) {

                    push @orderitems, $item;
                }

                # close order
                $query = qq|
					UPDATE oe SET
						closed = '1'
					WHERE id = $id|;
                $dbh->do($query) || $form->dberror($query);

                # reset shipped
                $query = qq|
					UPDATE orderitems SET
						ship = 0
					WHERE trans_id = $id|;
                $dbh->do($query) || $form->dberror($query);
            }

            $ordnumber ||=
              $form->update_defaults( $myconfig, $numberfld, $dbh, 1);

            #fixme:  Change this
            #also $credit_account is safe since it is local to this function
            #and pulled from the db. Same with oe_class_id.  --CT
            $query = qq|
		INSERT INTO oe (ordnumber, entity_credit_account, oe_class_id) 
		        VALUES ('$uid', $credit_account, $oe_class_id)|;
            $dbh->do($query) || $form->dberror($query);

            $query = qq|
				SELECT id
				FROM oe
				WHERE ordnumber = '$uid'|;
            ($id) = $dbh->selectrow_array($query);

            $ref->{employee_id} *= 1;

            $query = qq|
				UPDATE oe SET
					ordnumber = | . $dbh->quote($ordnumber) . qq|,
					transdate = current_date,
					amount = $amount,
					netamount = $netamount,
					reqdate = | . $form->dbquote( $ref->{reqdate}, SQL_DATE ) . qq|,
					taxincluded = |. $form->dbquote($ref->{taxincluded}) . qq|,
					shippingpoint = | . $dbh->quote( $ref->{shippingpoint} ) . qq|,
					notes = | . $dbh->quote( $ref->{notes} ) . qq|,
					curr = '$curr',
					person_id = | . $dbh->quote($ref->{person_id}) . qq|,
					intnotes = | . $dbh->quote( $ref->{intnotes} ) . qq|,
					shipvia = | . $dbh->quote( $ref->{shipvia} ) . qq|,
					language_code = '$ref->{language_code}',
					ponumber = | . $dbh->quote( $form->{ponumber} ) . qq|,
					department_id = $department_id
				WHERE id = $id|;
            $sth = $dbh->prepare($query);
            $sth->execute() || $form->dberror($query);

            $orderid_str =~ s/, $//;

            # add items
            $query = qq|
				INSERT INTO orderitems 
					(trans_id, parts_id, description,
					qty, sellprice, discount, unit, reqdate,
					project_id, ship, serialnumber, notes,
                                        precision)
				SELECT ?, parts_id, description,
					qty, sellprice, discount, unit, reqdate,
					project_id, ship, serialnumber, notes,
                                        precision
				  FROM orderitems
                                 WHERE trans_id IN ($orderid_str)|;

            $sth = $dbh->prepare($query);
            $sth->execute($id, @orderids) || $form->dberror($query);

           
        }
    }

    $rc = $dbh->commit;

    $rc;

}


1;

