open Log
open Lwt
open Vg_io
open Errors
    
(* Manage the Free LVs *)

let xenvmd_generation_tag = "xenvmd_gen"
  
let lvm_op_of_free_allocation vg connected_host allocation =
  let freeid = connected_host.Hostdb.free_LV_uuid in
  let lv = Lvm.Vg.LVs.find freeid vg.Lvm.Vg.lvs in
  let size = Lvm.Lv.size_in_extents lv in
  let segments = Lvm.Lv.Segment.linear size allocation in
  Lvm.Redo.Op.(LvExpand(freeid, { lvex_segments = segments }))

let allocation_of_lv vg lv_id =
  let open Lvm in
  Vg.LVs.find lv_id vg.Vg.lvs |> Lv.to_allocation

let generation_of_tag tag =
  match Stringext.split ~on:':' (Lvm.Name.Tag.to_string tag) with
  | [ x ; n ] when x=xenvmd_generation_tag -> (try Some (int_of_string n) with _ -> None)
  | _ -> None

let tag_of_generation n =
  match Lvm.Name.Tag.of_string (Printf.sprintf "%s:%d" xenvmd_generation_tag n) with
  | `Ok x -> x
  | `Error (`Msg y) -> failwith y

let generation_of_lv lv =
  List.fold_left
    (fun acc tag ->
       match generation_of_tag tag with
       | None -> acc
       | x -> x) None lv.Lvm.Lv.tags

let create name size =
  let creation_host = Unix.gethostname () in
  let creation_time = Unix.gettimeofday () |> Int64.of_float in
  Vg_io.write (fun vg ->
      Lvm.Vg.create vg name size ~creation_host ~creation_time
        ~tags:[tag_of_generation 1 |> Lvm.Name.Tag.to_string ]
    )
    
let perform_expand_free ef connected_host =
  let open Journal.Op in
  sector_size >>= fun sector_size ->

  (* Two operations to perform for this one journalled operation.
     So we need to be careful to ensure either that we only do
     each bit once, or that doing it twice is not harmful.

     Firstly, we've got to increase the allocation of the free
     pool for the host. We have numerical size increase
     journalled, and we have the allocation of the pool at the
     point we decided to do the operation. Therefore we can tell
     whether we've done this already or not by checking to see
     whether there are any new blocks allocated in the current
     LVM metadata.

     The second thing we need to do is tell the local allocator
     precisely which new blocks have been allocated for it.  We
     can't tell if we've done this already, so we need to ensure
     that the message is idempotent. Since if the LA has already
     received this update and may have already allocated blocks
     from it, it is imperative that there needs to be enough
     information in the message to allow the LA to ignore it
     away if it has already received it - this is the function
     of the generation count. We store the generation count in
     the LV tags so that it can be updated atomically alongside
     the increase in size. *)

  let msgs = ref [] in

  maybe_write
    (fun vg ->
       let current_allocation = allocation_of_lv vg connected_host.Hostdb.free_LV_uuid in
       let new_space = Lvm.Pv.Allocator.sub current_allocation ef.old_allocation |> Lvm.Pv.Allocator.size in
       if new_space = 0L then begin
         try
           let lv = Lvm.Vg.LVs.find connected_host.Hostdb.free_LV_uuid vg.Lvm.Vg.lvs in (* Not_found here caught by the try-catch block *)
           let extent_size = vg.Lvm.Vg.extent_size in (* in sectors *)
           let extent_size_mib = Int64.(div (mul extent_size (of_int sector_size)) (mul 1024L 1024L)) in
           let old_gen = generation_of_lv lv in
           let allocation =
             match Lvm.Pv.Allocator.find vg.Lvm.Vg.free_space Int64.(div ef.extra_size extent_size_mib) with
             | `Ok allocation -> allocation
             | `Error (`OnlyThisMuchFree (needed_extents, free_extents)) ->
               msgs := !msgs @ [
                   Printf.sprintf "LV %s expansion required, but number of free extents (%Ld) is less than needed extents (%Ld)"
                     connected_host.Hostdb.free_LV free_extents needed_extents;
                   "Expanding to use all the available space."];
               vg.Lvm.Vg.free_space
           in
           match Lvm.Vg.do_op vg (lvm_op_of_free_allocation vg connected_host allocation) with
           | `Ok (_,op1) ->
             let genops =
               match old_gen
               with
               | Some g -> [
                   Lvm.Redo.Op.LvRemoveTag (connected_host.Hostdb.free_LV_uuid, tag_of_generation g);
                   Lvm.Redo.Op.LvAddTag (connected_host.Hostdb.free_LV_uuid, tag_of_generation (g+1))]
               | None -> [
                   Lvm.Redo.Op.LvAddTag (connected_host.Hostdb.free_LV_uuid, tag_of_generation 1)]
             in
             `Ok (op1::genops)
           | `Error x -> `Error x
         with
         | Not_found ->
           `Error (`Msg (Printf.sprintf "Couldn't find the free LV for host: %s" connected_host.Hostdb.free_LV))
       end else `Ok [])
  >>= fun () ->
  Lwt_list.iter_s (fun msg -> debug "%s" msg) !msgs
  >>= fun () ->
  Fist.maybe_lwt_fail Xenvm_interface.FreePool1
  >>= fun () ->
  read (fun vg ->
      let lv = Lvm.Vg.LVs.find connected_host.Hostdb.free_LV_uuid vg.Lvm.Vg.lvs in
      let current_allocation = allocation_of_lv vg connected_host.Hostdb.free_LV_uuid in
      let old_allocation = ef.old_allocation in
      let new_extents = Lvm.Pv.Allocator.sub current_allocation old_allocation in
      let generation = generation_of_lv lv in
      match generation with
      | None -> (* This really should never happen *)
        error "Expecting a generation count in the tags of LV: %s" connected_host.Hostdb.free_LV
        >>= fun () ->
        Lwt.fail (Failure "Generation count missing")
      | Some g ->
        Lwt.return (new_extents, g))
  >>= fun (allocation, generation) ->
  let op = {
    FreeAllocation.blocks = allocation;
    FreeAllocation.generation = generation;
  } in
  Rings.FromLVM.push connected_host.Hostdb.from_LVM op
  >>= fun pos ->
  Rings.FromLVM.p_advance connected_host.Hostdb.from_LVM pos
  >>= fun result ->
  Fist.maybe_lwt_fail Xenvm_interface.FreePool2
  >>= fun () ->
  Lwt.return result

let perform t =
  debug "%s" (Journal.Op.sexp_of_t t |> Sexplib.Sexp.to_string_hum)
  >>= fun () ->
  match t with
  | Journal.Op.ExpandFree ef ->
    begin
      match Hostdb.get ef.Journal.Op.host with
      | Hostdb.Connected connected_host ->
        perform_expand_free ef connected_host
      | _ ->
        error "Journalled entry exists, but the host does not!"
    end

let perform ops =
  Lwt_list.iter_s perform ops
  >>= fun () ->
  return (`Ok ())

let journal = ref None

let start name =
  Vg_io.myvg >>= fun vg ->
  debug "Opening LV '%s' to use as a freePool journal" name
  >>= fun () ->
  ( match Vg_io.find vg name with
    | Some lv -> return lv
    | None -> assert false ) >>= fun v ->
  ( Vg_io.Volume.connect v >>= function
      | `Error _ -> fatal_error_t ("open " ^ name)
      | `Ok x -> return x )
  >>= fun device ->
  Journal.J.start ~client:"xenvmd" ~name:"allocation journal" device perform
  >>|= fun j' ->
  journal := Some j';
  return ()

let shutdown () =
  match !journal with
  | Some j ->
    Journal.J.shutdown j
  | None ->
    return ()

let send_allocation_to connected_host =
  fatal_error "resend_free_volumes unable to read LVM metadata"
    ( read (fun x -> return (`Ok x)) )
  >>= fun vg ->
  (* XXX: need to lock the host somehow. Ideally we would still service
          other queues while one host is locked. *)

  let from_lvm = connected_host.Hostdb.from_LVM in
  let freeid = connected_host.Hostdb.free_LV_uuid in
  let freename = connected_host.Hostdb.free_LV in

  fatal_error "resend_free_volumes"
    ( match try Some(Lvm.Vg.LVs.find freeid vg.Lvm.Vg.lvs) with _ -> None with
        | Some lv -> return (`Ok (Lvm.Lv.to_allocation lv))
        | None -> return (`Error (`Msg (Printf.sprintf "Failed to find LV %s" freename))) )
      >>= fun allocation ->
      let lv = Lvm.Vg.LVs.find freeid vg.Lvm.Vg.lvs in
      (match generation_of_lv lv with
       | Some g -> Lwt.return g
       | None ->
         error "Expecting a generation count in the tags of LV: %s" connected_host.Hostdb.free_LV
         >>= fun () ->
         Lwt.fail (Failure "Generation count missing")
      )
      >>= fun generation ->
      let op = {
        FreeAllocation.blocks = allocation;
        FreeAllocation.generation = generation;
      } in
      Rings.FromLVM.push from_lvm op
      >>= fun pos ->
      Rings.FromLVM.p_advance from_lvm pos


let resend_free_volume_to connected_host =
  let from_lvm = connected_host.Hostdb.from_LVM in
  Rings.FromLVM.p_state from_lvm
  >>= begin function
    | `Running -> return ()
    | `Suspended ->
      let rec wait () =
        Rings.FromLVM.p_state from_lvm
        >>= function
        | `Suspended ->
          Lwt_unix.sleep 0.5
          >>= fun () ->
          wait ()
        | `Running -> return () in
      wait ()
      >>= fun () ->
      send_allocation_to connected_host
  end

let resend_free_volumes () =
  let all = Hostdb.all () in
  Lwt_list.iter_s
    (function
      | host, Hostdb.Connected connected_host ->
        resend_free_volume_to connected_host
      | host, _ ->
        Lwt.return ()        
    ) all

let top_up_host config host connected_host =
  let open Config.Xenvmd in
  sector_size >>= fun sector_size ->
  read (Lwt.return) >>= fun vg ->
  match try Some(Lvm.Vg.LVs.find connected_host.Hostdb.free_LV_uuid vg.Lvm.Vg.lvs) with _ -> None with
  | Some lv ->
    let extent_size = vg.Lvm.Vg.extent_size in (* in sectors *)
    let extent_size_mib = Int64.(div (mul extent_size (of_int sector_size)) (mul 1024L 1024L)) in
    let size_mib = Int64.mul (Lvm.Lv.size_in_extents lv) extent_size_mib in
    if size_mib < config.host_low_water_mark then begin
      info "LV %s is %Ld MiB < low_water_mark %Ld MiB; allocating"
        connected_host.Hostdb.free_LV size_mib config.host_low_water_mark
      >>= fun () ->
      match !journal with
      | Some j ->
        let open Journal.Op in
        Journal.J.push j
          (ExpandFree
             { host;
               old_allocation=Lvm.Lv.to_allocation lv;
               extra_size=config.host_allocation_quantum })
        >>|= fun wait ->
        wait.Journal.J.sync ()
        >>= fun () ->
        Lwt.return true
      | None ->
        error "No journal configured!"
        >>= fun () ->
        Lwt.return false
    end else return false
  | None ->
    error "Host has disappeared!"
    >>= fun () ->
    Lwt.return false

let top_up_free_volumes config =
  let hosts = Hostdb.all () in
  Lwt_list.iter_s
    (function
      | host, Hostdb.Connected connected_host ->
        top_up_host config host connected_host
        >>= fun _ ->
        Lwt.return ()
      | _ -> Lwt.return ()
    ) hosts
